import { useEffect, useMemo, useRef, useState } from 'react'
import type { AgentDefInfo, AgentDefInput, ToolsAllowList } from '../types'
import {
  createAgentDef,
  deleteAgentDef,
  updateAgentDef,
  useAgentDefs,
  useConfiguredProviders,
} from '../hooks/useApi'

// ── Helpers ─────────────────────────────────────────────────────────────

const PROVIDER_LABELS: Record<string, string> = {
  anthropic: 'Anthropic',
  openai: 'OpenAI',
  openrouter: 'OpenRouter',
  ollama: 'Ollama',
}

const labelStyle: React.CSSProperties = {
  fontSize: 12,
  fontWeight: 500,
  color: 'var(--text-muted)',
}

const inputStyle: React.CSSProperties = {
  fontSize: 14,
  padding: '6px 10px',
  backgroundColor: 'var(--bg-sunken)',
  border: '1px solid var(--border)',
  borderRadius: 'var(--radius-sm)',
  color: 'var(--text-primary)',
  outline: 'none',
  fontFamily: 'inherit',
  width: '100%',
}

const textareaStyle: React.CSSProperties = {
  ...inputStyle,
  fontFamily: 'var(--font-mono)',
  minHeight: 180,
  resize: 'vertical',
  lineHeight: 1.5,
}

function Row({
  label, htmlFor, children, hint,
}: { label: string; htmlFor: string; children: React.ReactNode; hint?: string }) {
  return (
    <div style={{ display: 'grid', gridTemplateColumns: '140px 1fr', alignItems: 'start', gap: 12 }}>
      <label htmlFor={htmlFor} style={labelStyle}>{label}</label>
      <div>
        {children}
        {hint && (
          <div style={{ fontSize: 11, color: 'var(--text-faint)', marginTop: 4 }}>{hint}</div>
        )}
      </div>
    </div>
  )
}

/** Parse a free-form tools textarea (one opcode name per line, or "all")
 *  into the wire shape. Blank/whitespace lines are ignored. */
function parseToolsText(text: string): ToolsAllowList {
  const trimmed = text.trim().toLowerCase()
  if (trimmed === '' || trimmed === 'all') return 'all'
  const lines = text
    .split('\n')
    .map((l) => l.trim())
    .filter((l) => l.length > 0)
  return lines.length === 0 ? 'all' : lines
}

/** Render a ToolsAllowList back into the textarea's editable form. */
function toolsToText(tools: ToolsAllowList): string {
  if (tools === 'all') return 'all'
  return tools.join('\n')
}

/** The empty-form defaults for "New agent". */
function emptyInput(): AgentDefInput {
  return { id: '', name: '', provider: '', model: '', system: '', tools: 'all' }
}

/** Build an AgentDefInput from an existing AgentDefInfo for editing. */
function defToInput(d: AgentDefInfo): AgentDefInput {
  return {
    id: d.id,
    name: d.displayName,
    provider: d.provider,
    model: d.model,
    system: d.system ?? '',
    tools: d.tools,
  }
}

// ── Component ───────────────────────────────────────────────────────────

/** The Agents CRUD view. Lists every agent definition on the left; the
 *  right pane is either an editor (create or edit) or a detail view.
 *  Creating a new agent POSTs to /api/agents; editing PUTs
 *  /api/agents/:id; the trash button DELETEs. The list re-fetches after
 *  every mutation so the UI stays in sync with the backend.
 *
 *  The id is the canonical AgentDefId — [A-Za-z0-9_-]+, non-empty, no
 *  leading dot. The form validates this client-side so the user gets
 *  immediate feedback before the round-trip. */
export function AgentsView() {
  const { agents, loaded, error, refresh } = useAgentDefs()
  const { providers, loaded: providersLoaded } = useConfiguredProviders()

  // `editing` is the id of the def being edited, or `null` when no editor
  // is open. `creating` is true when the "New agent" form is open.
  const [editing, setEditing] = useState<string | null>(null)
  const [creating, setCreating] = useState(false)
  const [form, setForm] = useState<AgentDefInput>(emptyInput())
  const [toolsText, setToolsText] = useState('all')
  const [submitting, setSubmitting] = useState(false)
  const [formError, setFormError] = useState<string | null>(null)
  const [confirmingDelete, setConfirmingDelete] = useState<string | null>(null)

  // Ref holding the latest `agents` list so the seed effect can read it
  // without re-running on every poll tick. The seed must fire only when the
  // user picks a def (or starts creating) — NOT on every `agents` ref
  // change (the polled list gets a new array every 3s, which would
  // overwrite in-progress edits).
  const agentsRef = useRef(agents)
  agentsRef.current = agents

  // When the user picks a def to edit (or starts creating), seed the form.
  // Depends ONLY on `editing` / `creating` — the latest def is read from
  // `agentsRef.current` at seed time.
  useEffect(() => {
    if (creating) {
      setForm(emptyInput())
      setToolsText('all')
      setFormError(null)
      return
    }
    if (editing) {
      const d = agentsRef.current.find((a) => a.id === editing)
      if (d) {
        setForm(defToInput(d))
        setToolsText(toolsToText(d.tools))
        setFormError(null)
      }
    }
  }, [editing, creating])

  const selected = useMemo(
    () => (editing ? agents.find((a) => a.id === editing) ?? null : null),
    [editing, agents],
  )

  const validateForm = (): string | null => {
    const id = (form.id ?? '').trim()
    if (id.length === 0) return 'id is required'
    if (!/^[A-Za-z0-9_-]+$/.test(id)) return 'id must be [A-Za-z0-9_-]+ (no spaces or dots)'
    return null
  }

  const handleSubmit = async () => {
    const verr = validateForm()
    if (verr) { setFormError(verr); return }
    setSubmitting(true)
    setFormError(null)
    const trimmedId = (form.id ?? '').trim()
    if (creating) {
      const payload: AgentDefInput = {
        ...form,
        id: trimmedId,
        name: (form.name ?? '').trim() || undefined,
        provider: form.provider ?? '',
        model: form.model ?? '',
        system: form.system && form.system.trim().length > 0 ? form.system : null,
        tools: parseToolsText(toolsText),
      }
      const res = await createAgentDef(payload)
      setSubmitting(false)
      if (res) {
        refresh()
        setCreating(false)
        setEditing(res.id)
      } else {
        setFormError('Save failed — check the id is unique and the backend is reachable.')
      }
    } else if (editing) {
      // On edit, send new_id only when the id actually changed — the
      // backend renames (delete old + write new) when new_id differs
      // from the path id.
      const payload: AgentDefInput = {
        ...form,
        id: undefined,
        new_id: trimmedId !== editing ? trimmedId : undefined,
        name: (form.name ?? '').trim() || undefined,
        provider: form.provider ?? '',
        model: form.model ?? '',
        system: form.system && form.system.trim().length > 0 ? form.system : null,
        tools: parseToolsText(toolsText),
      }
      const res = await updateAgentDef(editing, payload)
      setSubmitting(false)
      if (res) {
        refresh()
        setEditing(res.id)
      } else {
        setFormError('Save failed — check the id is unique and the backend is reachable.')
      }
    }
  }

  const handleDelete = async (id: string) => {
    const ok = await deleteAgentDef(id)
    if (ok) {
      if (editing === id) setEditing(null)
      if (confirmingDelete === id) setConfirmingDelete(null)
      refresh()
    }
  }

  const handleNew = () => {
    setEditing(null)
    setCreating(true)
  }

  const handleCancel = () => {
    setCreating(false)
    setEditing(null)
    setFormError(null)
  }

  // ── Render ──────────────────────────────────────────────────────────
  return (
    <div className="flex flex-1 min-h-0" style={{ background: 'var(--bg-base)' }}>
      {/* List pane */}
      <div
        className="shrink-0 flex flex-col"
        style={{
          width: 280,
          background: 'var(--bg-surface)',
          borderRight: '1px solid var(--border)',
        }}
      >
        <div
          className="flex items-center justify-between px-3 py-2"
          style={{ borderBottom: '1px solid var(--border)' }}
        >
          <span
            className="text-xs font-semibold uppercase"
            style={{ color: 'var(--text-muted)', letterSpacing: '0.08em' }}
          >
            Agents ({agents.length})
          </span>
          <button
            type="button"
            className="btn btn-ghost flex items-center justify-center"
            style={{ width: 22, height: 22, padding: 0, fontSize: 14, lineHeight: 1 }}
            onClick={handleNew}
            aria-label="New agent"
            title="New agent"
          >
            +
          </button>
        </div>
        <div className="flex-1 overflow-y-auto sidebar-scroll">
          {!loaded && (
            <div className="px-3 py-2 text-xs" style={{ color: 'var(--text-faint)' }}>
              Loading…
            </div>
          )}
          {loaded && agents.length === 0 && (
            <div className="px-3 py-2 text-xs" style={{ color: 'var(--text-faint)' }}>
              No agents yet. Click + to create one.
            </div>
          )}
          {agents.map((a) => {
            const isActive = (creating ? false : editing === a.id) && !confirmingDelete
            return (
              <div
                key={a.id}
                data-testid={`agent-row-${a.id}`}
                className={`agent-row px-3 py-2 cursor-pointer${isActive ? ' selected' : ''}`}
                onClick={() => {
                  if (confirmingDelete === a.id) setConfirmingDelete(null)
                  setCreating(false)
                  setEditing(a.id)
                }}
              >
                <div className="flex items-center gap-2">
                  <span
                    className="text-sm truncate mr-auto"
                    style={{ color: 'var(--text-primary)', letterSpacing: 'var(--tracking-tight)' }}
                  >
                    {a.displayName || a.id}
                  </span>
                  {a.isDefault && (
                    <span
                      className="pill"
                      style={{
                        background: 'var(--bg-elevated)',
                        color: 'var(--text-faint)',
                        padding: '0 0.4em',
                        fontSize: '0.7em',
                      }}
                    >
                      default
                    </span>
                  )}
                </div>
                <div
                  className="text-xs mt-0.5 truncate"
                  style={{ color: 'var(--text-faint)' }}
                  title={`${a.provider || '—'} · ${a.model || '—'}`}
                >
                  {a.id} · {a.provider || '—'} · {a.model || '—'}
                </div>
              </div>
            )
          })}
        </div>
      </div>

      {/* Editor / detail pane */}
      <div className="flex-1 overflow-y-auto" style={{ padding: '24px 32px' }}>
        {error && (
          <div
            data-testid="agents-load-error"
            style={{ fontSize: 12, color: 'var(--needs-input)', marginBottom: 12 }}
          >
            Failed to load agents — the backend may be unreachable.
          </div>
        )}
        {!creating && !selected && (
          <div
            className="flex flex-col items-center justify-center"
            style={{ height: '100%', color: 'var(--text-faint)', gap: 8 }}
          >
            <div className="text-sm">Select an agent to edit, or click + to create one.</div>
          </div>
        )}
        {(creating || selected) && (
          <div
            className="flex flex-col gap-4"
            style={{ maxWidth: 640, margin: '0 auto' }}
            data-testid={creating ? 'agent-form-new' : `agent-form-${editing ?? ''}`}
          >
            <div className="flex items-center gap-2">
              <span className="text-lg font-semibold" style={{ color: 'var(--text-primary)' }}>
                {creating ? 'New agent' : (selected?.displayName || selected?.id || 'Agent')}
              </span>
              {selected?.isDefault && (
                <span
                  className="pill"
                  style={{ background: 'var(--bg-elevated)', color: 'var(--text-faint)', fontSize: 11, padding: '0 6px' }}
                >
                  default
                </span>
              )}
            </div>

            <Row label="Id" htmlFor="agent-id" hint="Canonical id ([A-Za-z0-9_-]+). Editing it renames the def (the old id is deleted).">
              <input
                id="agent-id"
                type="text"
                value={form.id ?? ''}
                onChange={(e) => setForm((f) => ({ ...f, id: e.target.value }))}
                style={inputStyle}
                placeholder="e.g. coder"
                autoComplete="off"
              />
            </Row>

            <Row label="Display name" htmlFor="agent-name" hint="Human-readable label shown in the UI. Defaults to the id when blank.">
              <input
                id="agent-name"
                type="text"
                value={form.name ?? ''}
                onChange={(e) => setForm((f) => ({ ...f, name: e.target.value }))}
                style={inputStyle}
                placeholder="e.g. Coder"
                autoComplete="off"
              />
            </Row>

            <Row label="Provider" htmlFor="agent-provider">
              <select
                id="agent-provider"
                value={form.provider ?? ''}
                onChange={(e) => setForm((f) => ({ ...f, provider: e.target.value }))}
                className="composer-select"
                style={inputStyle}
              >
                <option value="">(none)</option>
                {providersLoaded && providers.map((p) => (
                  <option key={p.name} value={p.name}>
                    {PROVIDER_LABELS[p.name] ?? p.name}
                  </option>
                ))}
                {/* Allow providers not in the configured list too — the
                    backend stores any string here. */}
                {form.provider && !providers.some((p) => p.name === form.provider) && (
                  <option value={form.provider}>{form.provider}</option>
                )}
              </select>
            </Row>

            <Row label="Model" htmlFor="agent-model" hint="Provider-specific model id, e.g. claude-sonnet-4-20250514.">
              <input
                id="agent-model"
                type="text"
                value={form.model ?? ''}
                onChange={(e) => setForm((f) => ({ ...f, model: e.target.value }))}
                style={inputStyle}
                placeholder="e.g. claude-sonnet-4-20250514"
                autoComplete="off"
              />
            </Row>

            <Row label="System prompt" htmlFor="agent-system" hint="The agent's system prompt. Optional — leave blank for none.">
              <textarea
                id="agent-system"
                value={form.system ?? ''}
                onChange={(e) => setForm((f) => ({ ...f, system: e.target.value }))}
                style={textareaStyle}
                placeholder="You are a careful coder…"
              />
            </Row>

            <Row
              label="Tools"
              htmlFor="agent-tools"
              hint="One opcode name per line (e.g. FILE_READ, ASK_HUMAN), or 'all' to allow every opcode."
            >
              <textarea
                id="agent-tools"
                value={toolsText}
                onChange={(e) => setToolsText(e.target.value)}
                style={{ ...textareaStyle, minHeight: 100 }}
                placeholder="all"
              />
            </Row>

            {formError && (
              <div
                data-testid="agent-form-error"
                style={{ fontSize: 12, color: 'var(--needs-input)' }}
              >
                {formError}
              </div>
            )}

            <div
              className="flex flex-col gap-2"
              style={{ borderTop: '1px solid var(--border)', paddingTop: 16 }}
            >
              <div className="flex gap-2">
                <button
                  type="button"
                  className="btn btn-primary px-3 py-2 rounded-lg text-sm font-medium"
                  onClick={handleSubmit}
                  disabled={submitting}
                  aria-label={creating ? 'Create agent' : 'Save agent'}
                >
                  {creating ? 'Create' : 'Save'}
                </button>
                <button
                  type="button"
                  className="btn btn-ghost px-3 py-2 rounded-lg text-sm font-medium"
                  onClick={handleCancel}
                >
                  Cancel
                </button>
                {!creating && selected && confirmingDelete !== selected.id && (
                  <button
                    type="button"
                    className="btn btn-danger-ghost px-3 py-2 rounded-lg text-sm font-medium"
                    style={{ marginLeft: 'auto' }}
                    onClick={() => setConfirmingDelete(selected.id)}
                    aria-label="Delete agent"
                  >
                    Delete
                  </button>
                )}
              </div>
              {!creating && selected && confirmingDelete === selected.id && (
                <div className="flex flex-col gap-2" data-testid="agent-delete-confirm">
                  <span className="text-sm" style={{ color: 'var(--needs-input)' }}>
                    Delete agent <strong>{selected.id}</strong>? This cannot be undone.
                  </span>
                  <div className="flex gap-2">
                    <button
                      type="button"
                      className="btn btn-danger-ghost px-3 py-2 rounded-lg text-sm font-medium"
                      style={{ background: 'var(--needs-input)', color: 'var(--text-primary)' }}
                      onClick={() => void handleDelete(selected.id)}
                      aria-label="Confirm delete"
                    >
                      Confirm delete
                    </button>
                    <button
                      type="button"
                      className="btn btn-ghost px-3 py-2 rounded-lg text-sm font-medium"
                      onClick={() => setConfirmingDelete(null)}
                    >
                      Cancel
                    </button>
                  </div>
                </div>
              )}
            </div>
          </div>
        )}
      </div>
    </div>
  )
}