import { useCallback, useEffect, useState } from 'react'
import type { SessionInfo, TabInfo } from '../types'
import type { ListsSnapshot, StreamClient } from '../types/stream'
import { streamClient } from '../lib/streamClient'
import { fetchJson, mapTabInfo, type TabInfoWire } from './useApi'

export function useListsStream(client?: StreamClient) {
  const sc = client ?? streamClient()
  const [tabs, setTabs] = useState<TabInfo[]>([])
  const [recentSessions, setRecentSessions] = useState<SessionInfo[]>([])
  const [archivedSessions, setArchivedSessions] = useState<SessionInfo[]>([])
  const [tabSessions, setTabSessions] = useState<SessionInfo[]>([])
  const [thinkingSessionIds, setThinkingSessionIds] = useState<string[]>([])
  // Flips true on the FIRST `lists` frame, regardless of content. App.tsx
  // uses this to switch from REST polling to WS push — the frame may carry
  // empty arrays on a quiet server, so we can't key off non-empty lengths.
  const [received, setReceived] = useState(false)

  /** Apply a snapshot to state. Shared by the WS path and the REST refresh so
   *  both normalize identically. */
  const applySnapshot = useCallback((snapshot: ListsSnapshot) => {
    setReceived(true)
    // The WS `lists` frame carries tabs as raw backend JSON (`TabInfoWire`,
    // snake_case health fields). Normalize to the camelCase TabInfo shape
    // the UI renders, mirroring the REST `/api/tabs` boundary in useTabs.
    setTabs((snapshot.tabs as TabInfoWire[]).map(mapTabInfo))
    setRecentSessions(snapshot.recentSessions)
    setArchivedSessions(snapshot.archivedSessions)
    // Active-tab-backed sessions are deduped out of recentSessions; carried
    // separately so a tab can still resolve its session (label + edit pencil).
    // Tolerate older servers that omit the field by defaulting to [].
    setTabSessions(snapshot.tabSessions ?? [])
    // Hydration set for the sidebar's thinking indicator (see
    // useSessionActivityStream). Tolerate older servers that omit the field.
    setThinkingSessionIds(snapshot.thinkingSessionIds ?? [])
  }, [])

  useEffect(() => {
    const unsub = sc.onLists(applySnapshot)
    return unsub
  }, [sc, applySnapshot])

  /** Re-fetch the snapshot over REST and apply it. Used after a turn
   *  completes so server-derived per-session values (e.g. `tokensUsed`) are
   *  current even for turns that did not go through the web send path.
   *  `useListsPoll` cannot serve this: it is disabled whenever the WS is
   *  live, which is the normal case. Never throws. */
  const refresh = useCallback(() => {
    void fetchJson<ListsSnapshot>('/api/lists').then((snapshot) => {
      if (snapshot && snapshot.tabs) applySnapshot(snapshot)
    })
  }, [applySnapshot])

  return { tabs, recentSessions, archivedSessions, tabSessions, thinkingSessionIds, received, refresh }
}