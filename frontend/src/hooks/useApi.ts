import { useState, useEffect, useCallback } from 'react'
import type {
  AgentInfo,
  DiscoverableWindow,
  HarnessInfo,
  ProviderInfo,
  SessionInfo,
  TabInfo,
  TabOrigin,
  TabStatus,
  TranscriptEntry,
} from '../types'

const POLL_INTERVAL = 3000

/** Raw `/api/tabs` (and WS `lists`) wire shape: the backend emits the health
 *  fields in snake_case. `index`/`kind`/`label`/`status`/`session_id` are
 *  already in their final shape; the rest map to camelCase TabInfo keys.
 *
 *  `label` is a HARNESS-ONLY fallback (the tmux window/session name), null for
 *  session-backed tabs — the snapshot sends no display `name`. The tab's
 *  display label is derived from the backing session (see `tabDisplayLabel`). */
export interface TabInfoWire {
  index: number
  kind: string
  label: string | null
  status: string
  session_id: string | null
  ext_modified?: boolean
  stale?: boolean
  origin?: string
  attach_command?: string | null
}

/** Normalize a backend tab object to the camelCase `TabInfo` shape the UI
 *  renders. Tolerant of Phase-1 objects lacking the new fields (back-compat):
 *  flags default to false, attachCommand to null, origin to undefined,
 *  label to null. */
export function mapTabInfo(wire: TabInfoWire): TabInfo {
  return {
    index: wire.index,
    kind: wire.kind,
    label: wire.label ?? null,
    status: wire.status as TabStatus,
    session_id: wire.session_id,
    extModified: wire.ext_modified ?? false,
    stale: wire.stale ?? false,
    origin: wire.origin as TabOrigin | undefined,
    attachCommand: wire.attach_command ?? null,
  }
}

/** Raw `/api/harnesses/discover` wire row: the backend emits a discoverable
 *  window in snake_case (`window_name`/`window_index`/`pane_pid`). */
export interface DiscoverableWindowWire {
  session: string
  window_name: string
  window_index: number
  pane_pid: number | null
}

/** Normalize a backend discovery row to the camelCase `DiscoverableWindow`
 *  shape the UI renders. */
export function mapDiscoverableWindow(wire: DiscoverableWindowWire): DiscoverableWindow {
  return {
    session: wire.session,
    windowName: wire.window_name,
    windowIndex: wire.window_index,
    panePid: wire.pane_pid,
  }
}

async function fetchJson<T>(url: string): Promise<T | null> {
  try {
    const res = await fetch(url)
    if (!res.ok) return null
    return await res.json() as T
  } catch {
    return null
  }
}

// ── Polled list hooks ───────────────────────────────────────────────────

export function useHarnesses() {
  const [harnesses, setHarnesses] = useState<HarnessInfo[]>([])
  const [error, setError] = useState(false)

  const poll = useCallback(async () => {
    const data = await fetchJson<HarnessInfo[]>('/api/harnesses')
    if (data) {
      setHarnesses(data)
      setError(false)
    } else {
      setError(true)
    }
  }, [])

  useEffect(() => {
    poll()
    const id = setInterval(poll, POLL_INTERVAL)
    return () => clearInterval(id)
  }, [poll])

  return { harnesses, error }
}

export function useRecentSessions() {
  const [sessions, setSessions] = useState<SessionInfo[]>([])
  const [error, setError] = useState(false)

  const poll = useCallback(async () => {
    const data = await fetchJson<SessionInfo[]>('/api/sessions')
    if (data) {
      setSessions(data)
      setError(false)
    } else {
      setError(true)
    }
  }, [])

  useEffect(() => {
    poll()
    const id = setInterval(poll, POLL_INTERVAL)
    return () => clearInterval(id)
  }, [poll])

  return { sessions, error }
}

export function useTabs() {
  const [tabs, setTabs] = useState<TabInfo[]>([])
  const [error, setError] = useState(false)

  const poll = useCallback(async () => {
    const data = await fetchJson<TabInfoWire[]>('/api/tabs')
    if (data) {
      setTabs(data.map(mapTabInfo))
      setError(false)
    } else {
      setError(true)
    }
  }, [])

  useEffect(() => {
    poll()
    const id = setInterval(poll, POLL_INTERVAL)
    return () => clearInterval(id)
  }, [poll])

  // `refresh` lets callers force an immediate poll instead of waiting for
  // the next interval — the new-tab compose-send flow uses this so the
  // just-created tab is in the local tabs list before it sets selectedId.
  return { tabs, error, refresh: poll }
}

export function useArchivedSessions() {
  const [sessions, setSessions] = useState<SessionInfo[]>([])
  const [error, setError] = useState(false)

  const poll = useCallback(async () => {
    const data = await fetchJson<SessionInfo[]>('/api/sessions/archived')
    if (data) {
      setSessions(data)
      setError(false)
    } else {
      setError(true)
    }
  }, [])

  useEffect(() => {
    poll()
    const id = setInterval(poll, POLL_INTERVAL)
    return () => clearInterval(id)
  }, [poll])

  return { sessions, error }
}

/** On-demand discovery of adoptable external tmux windows. Unlike the other
 *  list hooks this is NOT polled — discovery is an explicit, user-invoked
 *  action (bounded server-side by the adoption allow-list). `scan()` GETs
 *  `/api/harnesses/discover`, maps the wire rows, and replaces the list. On
 *  any failure the list is cleared and `error` is set. */
export function useDiscoverableWindows() {
  const [windows, setWindows] = useState<DiscoverableWindow[]>([])
  const [error, setError] = useState(false)

  const scan = useCallback(async () => {
    const data = await fetchJson<DiscoverableWindowWire[]>('/api/harnesses/discover')
    if (data) {
      setWindows(data.map(mapDiscoverableWindow))
      setError(false)
    } else {
      setWindows([])
      setError(true)
    }
  }, [])

  return { windows, error, scan }
}

// ── Transcript ──────────────────────────────────────────────────────────

export function useTranscript(sessionId: string | null) {
  const [entries, setEntries] = useState<TranscriptEntry[]>([])
  const [loading, setLoading] = useState(false)
  const [refreshCount, setRefreshCount] = useState(0)

  const refresh = useCallback(() => {
    setRefreshCount((c) => c + 1)
  }, [])

  useEffect(() => {
    if (!sessionId) {
      setEntries([])
      return
    }

    let cancelled = false
    setLoading(true)

    fetchJson<TranscriptEntry[]>(`/api/sessions/${encodeURIComponent(sessionId)}/transcript`)
      .then((data) => {
        if (cancelled) return
        setEntries(data ?? [])
        setLoading(false)
      })

    return () => { cancelled = true }
  }, [sessionId, refreshCount])

  return { entries, loading, refresh }
}

// ── Send message ────────────────────────────────────────────────────────

/** The `kind` discriminator the backend returns from POST
 *  /api/sessions/:id/send. `"slash"` means the input was a slash command
 *  whose response is TRANSIENT (never enters the transcript); `"assistant"`
 *  means a normal turn whose reply lands in the transcript. Modelled as an
 *  OPEN enum — the frontend must tolerate future/unknown kinds. */
export type SendKind = 'slash' | 'assistant' | (string & {})

/** Parsed 200 body of POST /api/sessions/:id/send. */
export interface SendResult {
  response: string
  kind: SendKind
}

export function useSendMessage(sessionId: string | null, onComplete: () => void) {
  const [sending, setSending] = useState(false)

  // `model` selects the per-session model for this turn (frontend-only state,
  // never persisted). When null/empty it is omitted from the body so the
  // backend falls back to the most-recent transcript `_te_model` (else the
  // global default).
  const send = useCallback(async (message: string, model?: string | null): Promise<SendResult | null> => {
    if (!sessionId || sending) return null
    setSending(true)
    try {
      const body: { message: string; model?: string } = { message }
      if (model && model.trim()) body.model = model
      const res = await fetch(`/api/sessions/${encodeURIComponent(sessionId)}/send`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(body),
      })
      if (!res.ok) {
        const err = await res.json().catch(() => ({}))
        console.error('Send failed:', err)
        return null
      }
      return (await res.json().catch(() => null)) as SendResult | null
    } catch (e) {
      console.error('Send error:', e)
      return null
    } finally {
      setSending(false)
      onComplete()
    }
  }, [sessionId, sending, onComplete])

  return { send, sending }
}

// ── Session mutators ────────────────────────────────────────────────────

/** Set or clear the user-provided session description. Passing null (or an
 *  all-whitespace string, which the backend normalises) clears the field. */
export async function setSessionDescription(sessionId: string, description: string | null): Promise<boolean> {
  try {
    const res = await fetch(`/api/sessions/${encodeURIComponent(sessionId)}/description`, {
      method: 'PUT',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ description }),
    })
    return res.ok
  } catch {
    return false
  }
}

/** Set the archive flag on a session. Pure UI hint — the session directory
 *  and transcript stay on disk. */
export async function setSessionArchived(sessionId: string, archived: boolean): Promise<boolean> {
  try {
    const res = await fetch(`/api/sessions/${encodeURIComponent(sessionId)}/archived`, {
      method: 'PUT',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ archived }),
    })
    return res.ok
  } catch {
    return false
  }
}

export async function setSessionPrompt(sessionId: string, prompt: string, name?: string): Promise<boolean> {
  try {
    const body: Record<string, string> = { prompt }
    if (name) body.name = name
    const res = await fetch(`/api/sessions/${encodeURIComponent(sessionId)}/prompt`, {
      method: 'PUT',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    })
    return res.ok
  } catch {
    return false
  }
}

// ── Agent + provider lookups ────────────────────────────────────────────

export function useAgents() {
  const [agents, setAgents] = useState<AgentInfo[]>([])

  useEffect(() => {
    fetchJson<AgentInfo[]>('/api/agents').then((data) => {
      if (Array.isArray(data)) setAgents(data)
    })
  }, [])

  return { agents }
}

export function useConfiguredProviders() {
  const [providers, setProviders] = useState<ProviderInfo[]>([])
  const [loaded, setLoaded] = useState(false)

  useEffect(() => {
    fetchJson<ProviderInfo[]>('/api/providers').then((data) => {
      if (Array.isArray(data)) setProviders(data)
      setLoaded(true)
    })
  }, [])

  return { providers, loaded }
}

/** Live fetch of available models for a provider. The backend proxies to the
 *  provider's `/v1/models` endpoint using vault credentials. Returns the
 *  widened `{name, contextWindow}[]` shape (T11). Returns an empty list on
 *  any failure. Never throws. */
export interface ProviderModelInfo {
  name: string
  contextWindow: number
}

export async function fetchProviderModels(provider: string): Promise<ProviderModelInfo[]> {
  const data = await fetchJson<ProviderModelInfo[]>(`/api/providers/${encodeURIComponent(provider)}/models`)
  return Array.isArray(data) ? data : []
}

/** Fetch the full context-window spec for a single model — the denominator
 *  for the "tokens / context window" session stat (roadmap § 7b deliverable
 *  7). Returns null on any failure. Never throws. */
export interface ModelContext {
  contextWindow: number
  maxOutputTokens: number
}

export async function fetchModelContext(provider: string, model: string): Promise<ModelContext | null> {
  return fetchJson<ModelContext>(`/api/providers/${encodeURIComponent(provider)}/models/${encodeURIComponent(model)}/context`)
}

// ── Tab mutators ────────────────────────────────────────────────────────

/** Response from POST /api/tabs/new. */
export interface NewTabResponse {
  tab_index: number
  session_id: string | null
  kind: string
}

/** The body for POST /api/tabs/new. The `kind` discriminator selects the tab
 *  type; the remaining fields are kind-specific. `shell`/`ssh` kinds are
 *  stubbed 501 by the gateway until Phase 4 wires the executor.
 *
 *  Note: TS fields use the WIRE's snake_case (`branch_from`, `harness_id`)
 *  directly — `createTab` passes them through unchanged. */
export interface CreateTabBody {
  kind: string                  // "provider" | "harness" | "branch" | "attach"
  provider?: string
  model?: string
  agent?: string
  branch_from?: string
  harness_id?: string
}

/** Create a new tab via the unified POST /api/tabs/new endpoint. For
 *  provider-backed sessions the response includes a `session_id` usable to
 *  load the transcript; for raw shell tabs it is null. */
export async function createTab(body: CreateTabBody): Promise<NewTabResponse | null> {
  try {
    const res = await fetch('/api/tabs/new', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    })
    if (!res.ok) return null
    return await res.json() as NewTabResponse
  } catch {
    return null
  }
}

/** Close a tab by index. Returns true if the backend accepted the close. */
export async function closeTab(index: number): Promise<boolean> {
  try {
    const res = await fetch(`/api/tabs/${index}/close`, { method: 'POST' })
    return res.ok
  } catch {
    return false
  }
}

/** Dismiss an exited/orphaned tab by index — removes the live row. The
 *  underlying session stays in Recent Sessions (session.json is untouched). */
export async function dismissTab(index: number): Promise<boolean> {
  try {
    const res = await fetch(`/api/tabs/${index}/dismiss`, { method: 'POST' })
    return res.ok
  } catch {
    return false
  }
}

/** Acknowledge an externally-modified tab by index — clears its
 *  `ext_modified` flag on the registry entry. */
export async function acknowledgeTab(index: number): Promise<boolean> {
  try {
    const res = await fetch(`/api/tabs/${index}/acknowledge`, { method: 'POST' })
    return res.ok
  } catch {
    return false
  }
}

/** Release an adopted harness by tab index — Seal stops managing it and
 *  clears its `@seal_id` marker, but never kills the underlying tmux
 *  window. Distinct from close/dismiss. */
export async function releaseHarness(index: number): Promise<boolean> {
  try {
    const res = await fetch(`/api/tabs/${index}/release`, { method: 'POST' })
    return res.ok
  } catch {
    return false
  }
}

/** Destroy a harness by tab index — terminates its processes (kills the tmux
 *  window) and archives its session (the transcript is kept on disk).
 *  Distinct from release (which never kills) and close.
 *
 *  `confirmAdopted` must be true to destroy an ADOPTED harness: killing a
 *  window Seal did not create breaks the "release never kills" contract, so
 *  the backend fail-closes unless the caller explicitly confirms. Sent as
 *  `confirm_adopted` in the body. */
export async function destroyHarness(index: number, confirmAdopted: boolean): Promise<boolean> {
  try {
    const res = await fetch(`/api/tabs/${index}/destroy`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ confirm_adopted: confirmAdopted }),
    })
    return res.ok
  } catch {
    return false
  }
}

// ── Adoption ────────────────────────────────────────────────────────────

/** Adopt an existing tmux window. Returns whether it succeeded and the Seal
 *  session id created for the adopted harness (so the caller can navigate
 *  into its conversation and send a first message). `sessionId` is null on
 *  failure or if the server didn't supply one. */
export async function adoptWindow(
  session: string,
  window: string,
  windowIndex: number | null = null,
): Promise<{ ok: boolean; sessionId: string | null }> {
  try {
    // The window INDEX is the only identifier unique within a session (names
    // repeat). The detected-windows picker supplies it so adoption targets
    // the chosen window; manual entry has no index, so it's omitted and the
    // server falls back to matching by name.
    const body: Record<string, unknown> = { session, window, consent_confirmed: true }
    if (windowIndex !== null) body.window_index = windowIndex
    const res = await fetch('/api/adopt', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    })
    if (!res.ok) return { ok: false, sessionId: null }
    const data = (await res.json().catch(() => ({}))) as { session_id?: string | null }
    return { ok: true, sessionId: data.session_id ?? null }
  } catch {
    return { ok: false, sessionId: null }
  }
}