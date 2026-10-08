/** Configurable second-line fields for sidebar tab rows.
 *
 *  Each tab row in the "Active Tabs" (and "Running Harnesses") section shows
 *  a secondary line of metadata below the tab label. The set of fields shown
 *  — and their display order — is user-configurable via the gear icon at the
 *  bottom of the sidebar. The selection persists to localStorage so it
 *  survives reloads.
 *
 *  Available fields:
 *    - provider — the LLM provider badge (single-letter colored glyph)
 *    - model    — the shortened model id (e.g. "sonnet-4")
 *    - repo     — the repo name derived from the session's repoUrl
 *    - channel  — the starting channel (e.g. "web", "signal", "cli")
 *    - agent    — the display name of the bound agent */

export type TabLineField = 'provider' | 'model' | 'repo' | 'channel' | 'agent'

/** Human-readable labels for the config popover. */
export const TAB_LINE_FIELD_LABELS: Record<TabLineField, string> = {
  provider: 'Provider',
  model:    'Model',
  repo:     'Repo',
  channel:  'Channel',
  agent:    'Agent',
}

/** All valid field ids in canonical order — used for validation and for
 *  rendering the available-fields list in the config popover. */
export const ALL_TAB_LINE_FIELDS: TabLineField[] = ['provider', 'model', 'repo', 'channel', 'agent']

/** The default field selection and order: repo + channel. Provider/model
 *  are de-emphasized (still selectable via the config popover) — repo
 *  provenance and starting channel are the most identifying per-tab signals.
 *  Agent is NOT in the default; the user can add it explicitly if desired. */
export const DEFAULT_TAB_LINE_FIELDS: TabLineField[] = ['repo', 'channel']

const STORAGE_KEY = 'seal.tabLineFields'

/** Load the persisted field selection from localStorage. Returns the default
 *  when localStorage is unavailable, the stored value is missing, or the
 *  stored value fails validation. Never throws. */
export function loadTabLineFields(): TabLineField[] {
  if (typeof localStorage === 'undefined') return [...DEFAULT_TAB_LINE_FIELDS]
  try {
    const raw = localStorage.getItem(STORAGE_KEY)
    if (!raw) return [...DEFAULT_TAB_LINE_FIELDS]
    return parseTabLineFields(raw)
  } catch {
    return [...DEFAULT_TAB_LINE_FIELDS]
  }
}

/** Save the field selection to localStorage. No-op when localStorage is
 *  unavailable. Never throws. */
export function saveTabLineFields(fields: TabLineField[]): void {
  if (typeof localStorage === 'undefined') return
  try {
    localStorage.setItem(STORAGE_KEY, JSON.stringify(fields))
  } catch {
    // Silently ignore — the config is cosmetic, not worth crashing for.
  }
}

/** Parse a raw JSON string into a validated TabLineField[]. Falls back to
 *  the default on any validation failure (not an array, contains unknown
 *  fields, empty array, or contains duplicates). */
export function parseTabLineFields(raw: string): TabLineField[] {
  let parsed: unknown
  try {
    parsed = JSON.parse(raw)
  } catch {
    return [...DEFAULT_TAB_LINE_FIELDS]
  }
  if (!Array.isArray(parsed)) return [...DEFAULT_TAB_LINE_FIELDS]
  const valid = parsed.filter(
    (f: unknown): f is TabLineField =>
      typeof f === 'string' && (ALL_TAB_LINE_FIELDS as string[]).includes(f),
  )
  // Reject empty — always show at least the default.
  if (valid.length === 0) return [...DEFAULT_TAB_LINE_FIELDS]
  // Reject duplicates.
  const seen = new Set<string>()
  for (const f of valid) {
    if (seen.has(f)) return [...DEFAULT_TAB_LINE_FIELDS]
    seen.add(f)
  }
  return valid
}

/** Move a field one position up in the list. Returns a new array (immutable).
 *  No-op when the field is already first or not found. */
export function moveFieldUp(fields: TabLineField[], field: TabLineField): TabLineField[] {
  const idx = fields.indexOf(field)
  if (idx <= 0) return fields
  const next = [...fields]
  const tmp = next[idx - 1]!
  next[idx - 1] = next[idx]!
  next[idx] = tmp
  return next
}

/** Move a field one position down in the list. Returns a new array
 *  (immutable). No-op when the field is already last or not found. */
export function moveFieldDown(fields: TabLineField[], field: TabLineField): TabLineField[] {
  const idx = fields.indexOf(field)
  if (idx < 0 || idx >= fields.length - 1) return fields
  const next = [...fields]
  const tmp = next[idx + 1]!
  next[idx + 1] = next[idx]!
  next[idx] = tmp
  return next
}

/** Toggle a field's presence in the list. When adding, the field is appended
 *  at the end. Returns a new array (immutable). Refuses to remove the last
 *  field — always keeps at least one. */
export function toggleField(fields: TabLineField[], field: TabLineField): TabLineField[] {
  const idx = fields.indexOf(field)
  if (idx >= 0) {
    // Remove — but never empty the list.
    if (fields.length <= 1) return fields
    return fields.filter((f) => f !== field)
  }
  // Add at end.
  return [...fields, field]
}