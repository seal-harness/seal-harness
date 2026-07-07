import { useEffect, useState } from 'react'
import type { SessionInfo, TabInfo } from '../types'
import type { ListsSnapshot, StreamClient } from '../types/stream'
import { streamClient } from '../lib/streamClient'
import { mapTabInfo, type TabInfoWire } from './useApi'

export function useListsStream(client?: StreamClient) {
  const sc = client ?? streamClient()
  const [tabs, setTabs] = useState<TabInfo[]>([])
  const [recentSessions, setRecentSessions] = useState<SessionInfo[]>([])
  const [archivedSessions, setArchivedSessions] = useState<SessionInfo[]>([])
  const [tabSessions, setTabSessions] = useState<SessionInfo[]>([])

  useEffect(() => {
    const unsub = sc.onLists((snapshot: ListsSnapshot) => {
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
    })
    return unsub
  }, [sc])

  return { tabs, recentSessions, archivedSessions, tabSessions }
}