// Seal Harness frontend types — rebuilt against the Seal gateway's wire
// shapes (the widened REST surface from T10/T11 + the StreamBroker events
// from T2). Field names match the gateway's JSON exactly; the UI-internal
// derivation types (Message/MessageContent) are structural mirrors of the
// reference layout.

// ── Agent ──────────────────────────────────────────────────────────────

export type AgentStatus = 'needs-input' | 'thinking' | 'idle' | 'completed'

export interface Agent {
  id: string
  name: string
  status: AgentStatus
  tokenCount: string
  description?: string
}

// ── Harness ────────────────────────────────────────────────────────────

/** Liveness of a harness, as the gateway reports it. Maps the backend's
 *  `Liveness` (`Idle`/`Thinking`/`AwaitingInput`/`Exited`/`Orphaned`) to
 *  the UI-facing vocabulary. */
export type HarnessActivity = 'thinking' | 'idle' | 'needs-input' | 'stopped'

export interface HarnessInfo {
  name: string
  activity: HarnessActivity
}

// ── Session ────────────────────────────────────────────────────────────

/** A session row from `GET /api/sessions` / `GET /api/sessions/archived`.
 *  Matches the gateway's `SessionInfo` JSON (the widened `SessionMeta` +
 *  channel provenance from `MessageSource`). */
export interface SessionInfo {
  id: string
  /** The agent definition bound to this session at init (from `default_agent`
   *  in `config.toml`), or null. */
  agent: string | null
  /** `"session:<provider>"` — the runtime kind + provider label. */
  runtime: string
  model: string
  lastActive: string
  createdAt: string
  description: string | null
  autoSummary: string | null
  firstMessageSnippet: string | null
  /** Communications channel name of the session origin (e.g. "signal",
   *  "telegram", "cli"), or null when no source was recorded. */
  channel: string | null
  /** Channel user id of the session origin, or null when the channel
   *  carries no user id (e.g. `seal tui` → the `cli` channel). */
  channelUserId: string | null
}

/** Cascade used to pick the display title for a session.
 *  Order: user-set description → model-generated summary → snippet of
 *  the first user message → agent name → short id prefix. */
export function sessionDisplayTitle(s: SessionInfo): string {
  if (s.description)         return s.description
  if (s.autoSummary)         return s.autoSummary
  if (s.firstMessageSnippet) return s.firstMessageSnippet
  if (s.agent)               return s.agent
  return s.id.slice(0, 12) || 'New session'
}

/** Strip the Anthropic date suffix and verbose family prefix from a
 *  model id so we can fit it in tight UI surfaces. Examples:
 *    claude-sonnet-4-20250514 → sonnet-4
 *    other ids pass through unchanged. */
export function shortenModel(model: string): string {
  const m = model.match(/claude-(\w+-\d+)/)
  return m ? m[1]! : model
}

/** Agent + communications channel formatted as "agent · channel:userId"
 *  (with the middle dot). The model is deliberately omitted — it can change
 *  over a session's lifetime. The channel piece is shown only when the
 *  origin carries a channel user id; sessions with no channel user id
 *  (e.g. `seal tui` — the `cli` channel) show just the agent. Skips either
 *  piece if missing. */
export function sessionSubtitle(s: { agent?: string | null; channel?: string | null; channelUserId?: string | null }): string {
  const parts: string[] = []
  if (s.agent) parts.push(s.agent)
  if (s.channelUserId) parts.push(`${s.channel ?? ''}:${s.channelUserId}`)
  return parts.join(' · ')
}

// ── Tab ─────────────────────────────────────────────────────────────────

/** Liveness of a tab/harness. `exited` (harness process died, window still
 *  present) and `orphaned` (no live window for this id) replace the old
 *  collapsed `crashed` value — the backend now reports them distinctly. */
export type TabStatus = 'running' | 'idle' | 'exited' | 'orphaned'

/** Where a harness entered the registry, surfaced as a small pill. */
export type TabOrigin = 'spawned' | 'discovered' | 'adopted'

export interface TabInfo {
  index: number
  kind: string
  /** Harness-only fallback label (the tmux window/session name), or null for
   *  session-backed tabs. The tab's DISPLAY label is NOT this field — it is
   *  derived from the backing session's title (see `tabDisplayLabel`), so a
   *  session-backed tab reads identically to its Recent Sessions row. This
   *  `label` is only the last-resort fallback for harness tabs whose session
   *  has not (yet) resolved. */
  label: string | null
  status: TabStatus
  session_id: string | null
  /** The harness window's name/session changed out-of-band since Seal last
   *  reconciled it. An orthogonal flag (not a liveness state) — shows a
   *  ⚠ "edited" pill + an Acknowledge action. */
  extModified?: boolean
  /** The last reconcile sweep failed for this entry, so its liveness is held
   *  from the previous tick. Renders a subtle dimmed cue, no distinct glyph. */
  stale?: boolean
  /** How the harness entered the registry. */
  origin?: TabOrigin
  /** A copyable `tmux attach -t …` command for live rows, or null when the
   *  tab has no attachable window. */
  attachCommand?: string | null
}

/** Resolve the display label for a tab. The label is the backing SESSION's
 *  title (so a tab reads identically to its Recent Sessions row); only when no
 *  session resolves do we fall back to the harness `label`, and as an absolute
 *  last resort an ellipsis — NEVER blank. Centralized so every tab-label
 *  consumer (sidebar rows, harness header, chat-header title) agrees. */
export function tabDisplayLabel(tab: TabInfo, session: SessionInfo | null | undefined): string {
  if (session) return sessionDisplayTitle(session)
  return tab.label ?? '…'
}

/** Find the session backing a tab id across the live (recents), archived, and
 *  active-tab lists. `tabSessions` carries the SessionInfo for sessions that
 *  back an open tab — those are deduped OUT of recents/archived by the backend
 *  and the tab snapshot is meta-free, so without consulting it an OPEN tab's
 *  session would resolve nowhere (no chat-header pencil, stale title). Returns
 *  undefined when the id is null/unknown. */
export function findSession(
  id: string | null | undefined,
  sessions: SessionInfo[],
  archivedSessions: SessionInfo[],
  tabSessions: SessionInfo[] = [],
): SessionInfo | undefined {
  if (!id) return undefined
  return sessions.find((s) => s.id === id)
    ?? archivedSessions.find((s) => s.id === id)
    ?? tabSessions.find((s) => s.id === id)
}

// ── Discovery (harness adoption) ───────────────────────────────────────

/** An external (unmanaged) tmux window that Seal discovered via an on-demand
 *  discovery scan and could be adopted. Transient, metadata-only — it is NOT
 *  a registry entry and carries no capture capability. Mirrors the backend
 *  `DiscoverableWindow` JSON (snake_case `window_name`/`window_index`/
 *  `pane_pid`), mapped to camelCase at the fetch boundary. */
export interface DiscoverableWindow {
  session: string
  windowName: string
  windowIndex: number
  /** The pane's shell PID, or null when tmux reported none. */
  panePid: number | null
}

// ── Agent defs + Providers (gateway lookups) ───────────────────────────

export interface AgentInfo {
  name: string
  isDefault: boolean
}

export interface ProviderInfo {
  name: string
  /** True for the provider Seal is configured to use (from CLI flag or
   *  config file). At most one entry has it set to true. */
  isDefault?: boolean
  /** The configured default model for this provider, if any. */
  defaultModel?: string
}

// ── Agent CRUD (full def) ──────────────────────────────────────────────

/** The opcode-allow-list wire shape: the string "all" or an array of
 *  opcode-name strings. Mirrors the backend's 'AllowList OpName' JSON
 *  encoding. */
export type ToolsAllowList = 'all' | string[]

/** The full agent definition returned by GET /api/agents (now widened to
 *  include every field) and GET /api/agents/:id, and accepted by POST
 *  /api/agents + PUT /api/agents/:id. `id` and `name` are both present:
 *  `id` is the canonical AgentDefId (used to address the def), `name` is
 *  the legacy wire field that the SessionSetup dropdown echoes back as
 *  body.agent (also the AgentDefId text), and `displayName` is the
 *  human-readable name from the def's frontmatter. */
export interface AgentDefInfo {
  id: string
  name: string
  isDefault: boolean
  displayName: string
  provider: string
  model: string
  system: string | null
  tools: ToolsAllowList
  created_at: string
  updated_at: string
  session: string
}

/** The body for POST /api/agents + PUT /api/agents/:id. The `id` is
 *  required for POST (the caller picks it); PUT takes the id from the
 *  path. To RENAME an existing def on PUT, send `new_id` with the new
 *  AgentDefId — the backend deletes the old id and writes the new one
 *  (provenance preserved). Provenance fields (created_at / updated_at /
 *  session) are stamped server-side and never sent by the client. */
export interface AgentDefInput {
  id?: string
  new_id?: string
  name?: string
  provider?: string
  model?: string
  system?: string | null
  tools?: ToolsAllowList
}

// ── Skill CRUD ─────────────────────────────────────────────────────────

/** The full skill returned by GET /api/skills / GET /api/skills/:id, and
 *  accepted by POST /api/skills + PUT /api/skills/:id. Mirrors the
 *  backend's 'Skill' JSON (snake_case keys match the wire). */
export interface SkillInfo {
  id: string
  description: string
  body: string
  created_at: string
  updated_at: string
  session: string
}

/** The body for POST /api/skills + PUT /api/skills/:id. The `id` is
 *  required for POST; PUT takes the id from the path. To RENAME an
 *  existing skill on PUT, send `new_id` with the new SkillId. */
export interface SkillInput {
  id?: string
  new_id?: string
  description?: string
  body?: string
}

// ── Transcript ─────────────────────────────────────────────────────────

export interface TranscriptEntry {
  id: string
  timestamp: string
  direction: 'request' | 'response'
  payload: string
  harness: string | null
  model: string | null
  /** The full, verbatim on-disk transcript.jsonl line for this entry — all 9
   *  `_te_*` fields including `_te_metadata`, byte-faithful to disk. Surfaced in
   *  the "View raw JSON (message)" modal. Required, never optional, per the
   *  governing principle: Seal always makes EVERYTHING visible to the user;
   *  raw views must never silently hide fields. */
  raw: string
  /** Set to `true` when this entry was delivered via an `entry-update` event,
   *  indicating the entry is still being streamed and may be updated further.
   *  Absent (undefined) or false for finalized `entry` events. */
  streaming?: boolean
}

// ── Message derivation (UI-internal, from TranscriptEntry) ─────────────

export interface CodeSpan {
  type: 'kw' | 'str' | 'fn' | 'cm' | 'text'
  text: string
}

export interface ToolCallInfo {
  id: string                // stable id (from the provider's tool_use_id when available)
  name: string              // tool name, e.g. "shell"
  input: unknown            // argument payload
  result?: string           // matching tool_result content, pretty-printed
  resultIsError?: boolean
  exitCode?: number | null  // exit code parsed from the result, when available
}

/** A tool-definition block, shown collapsed by default. `count` and
 *  `names` drive the compact collapsed header (e.g. "3 tools: shell, read,
 *  edit"); `json` is the verbatim tools array the LLM was sent, rendered
 *  in a pretty-printed <pre> when expanded. Mirrors the System-prompt row
 *  so the user can see — at a glance and on demand — what the LLM was
 *  told it could do. */
export interface ToolDefsBlock {
  count: number
  names: string[]
  json: string  // pretty-printed JSON of the tools array
}

export interface MessageContent {
  id?: string              // stable per-block id used for #fragment deep-links
  text?: string
  codeBlock?: CodeSpan[][]
  listItems?: string[]
  orderedItems?: string[]
  collapsedText?: string   // System-prompt block, shown collapsed by default, expandable
  thinkingText?: string    // claude-code "thinking" block, collapsed by default under a "Thinking" label
  rawJson?: string         // raw JSON, hidden by default, toggleable
  toolCall?: ToolCallInfo  // assistant tool invocation (with matched result when available)
  toolDefs?: ToolDefsBlock // tool definitions block, collapsed with count/names; full JSON on expand
}

export interface Message {
  id: string
  /** Raw transcript-entry id (`_te_id`) this row was derived from. Present
   *  on branchable rows (user + assistant); absent on synthesized rows
   *  (e.g. the System prompt row). Used as the branch boundary key. */
  entryId?: string
  agentName: string
  agentStatus: AgentStatus
  timestamp: string
  blocks: MessageContent[]
  /** Set on SYNTHETIC optimistic messages (pending-thinking, remote-thinking)
   *  to show the TypingIndicator while the local UI awaits the LLM response.
   *  Distinct from `streaming` — this is local optimistic state, not a
   *  transcript-entry flag. */
  isGenerating?: boolean
  /** Set to `true` when the derived message originates from a transcript entry
   *  with `streaming: true` (i.e. an `entry-update` event — the entry is still
   *  being written). Causes the TypingIndicator to render. Cleared (false or
   *  absent) once the entry is finalized via a normal `entry` event. Kept
   *  DISTINCT from `isGenerating` to avoid conflating transcript-streaming with
   *  the local optimistic-pending UI. */
  streaming?: boolean
  meta?: string            // e.g. model name, token usage
  rawJson?: string         // full transcript-entry payload (pretty-printed when JSON)
  /** Marks a TRANSIENT slash-command output bubble (kind:"slash" send
   *  response). These rows are NOT persisted — they never enter the
   *  transcript and vanish on reload. Rendered in a muted "command output"
   *  style with a "command output — not saved" label. */
  slashBubble?: boolean
}