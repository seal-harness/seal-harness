import { useEffect, useMemo, useRef, useState } from 'react'
import type { SkillInfo, SkillInput } from '../types'
import {
  createSkill,
  deleteSkill,
  updateSkill,
  useSkills,
} from '../hooks/useApi'

// ── Helpers ─────────────────────────────────────────────────────────────

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
  minHeight: 280,
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

function emptyInput(): SkillInput {
  return { id: '', description: '', body: '' }
}

function skillToInput(s: SkillInfo): SkillInput {
  return { id: s.id, description: s.description, body: s.body }
}

// ── Component ───────────────────────────────────────────────────────────

/** The Skills CRUD view. Lists every skill on the left; the right pane is
 *  an editor (create or edit). Creating POSTs /api/skills; editing PUTs
 *  /api/skills/:id; the trash button DELETEs. The list re-fetches after
 *  every mutation. The id is [A-Za-z0-9_-]+ — validated client-side. */
export function SkillsView() {
  const { skills, loaded, error, refresh } = useSkills()

  const [editing, setEditing] = useState<string | null>(null)
  const [creating, setCreating] = useState(false)
  const [form, setForm] = useState<SkillInput>(emptyInput())
  const [submitting, setSubmitting] = useState(false)
  const [formError, setFormError] = useState<string | null>(null)
  const [confirmingDelete, setConfirmingDelete] = useState<string | null>(null)

  // Ref holding the latest `skills` list so the seed effect can read it
  // without re-running on every poll tick (the polled list gets a new
  // array every 3s, which would overwrite in-progress edits).
  const skillsRef = useRef(skills)
  skillsRef.current = skills

  // Seed the form ONLY when the user picks a skill (or starts creating) —
  // not on every `skills` ref change.
  useEffect(() => {
    if (creating) {
      setForm(emptyInput())
      setFormError(null)
      return
    }
    if (editing) {
      const s = skillsRef.current.find((x) => x.id === editing)
      if (s) {
        setForm(skillToInput(s))
        setFormError(null)
      }
    }
  }, [editing, creating])

  const selected = useMemo(
    () => (editing ? skills.find((s) => s.id === editing) ?? null : null),
    [editing, skills],
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
      const payload: SkillInput = {
        ...form,
        id: trimmedId,
        description: form.description ?? '',
        body: form.body ?? '',
      }
      const res = await createSkill(payload)
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
      const payload: SkillInput = {
        ...form,
        id: undefined,
        new_id: trimmedId !== editing ? trimmedId : undefined,
        description: form.description ?? '',
        body: form.body ?? '',
      }
      const res = await updateSkill(editing, payload)
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
    const ok = await deleteSkill(id)
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
            Skills ({skills.length})
          </span>
          <button
            type="button"
            className="btn btn-ghost flex items-center justify-center"
            style={{ width: 22, height: 22, padding: 0, fontSize: 14, lineHeight: 1 }}
            onClick={handleNew}
            aria-label="New skill"
            title="New skill"
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
          {loaded && skills.length === 0 && (
            <div className="px-3 py-2 text-xs" style={{ color: 'var(--text-faint)' }}>
              No skills yet. Click + to create one.
            </div>
          )}
          {skills.map((s) => {
            const isActive = (creating ? false : editing === s.id) && !confirmingDelete
            return (
              <div
                key={s.id}
                data-testid={`skill-row-${s.id}`}
                className={`agent-row px-3 py-2 cursor-pointer${isActive ? ' selected' : ''}`}
                onClick={() => {
                  if (confirmingDelete === s.id) setConfirmingDelete(null)
                  setCreating(false)
                  setEditing(s.id)
                }}
              >
                <div
                  className="text-sm truncate"
                  style={{ color: 'var(--text-primary)', letterSpacing: 'var(--tracking-tight)' }}
                  title={s.id}
                >
                  {s.id}
                </div>
                <div
                  className="text-xs mt-0.5 truncate"
                  style={{ color: 'var(--text-faint)' }}
                  title={s.description}
                >
                  {s.description}
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
            data-testid="skills-load-error"
            style={{ fontSize: 12, color: 'var(--needs-input)', marginBottom: 12 }}
          >
            Failed to load skills — the backend may be unreachable.
          </div>
        )}
        {!creating && !selected && (
          <div
            className="flex flex-col items-center justify-center"
            style={{ height: '100%', color: 'var(--text-faint)', gap: 8 }}
          >
            <div className="text-sm">Select a skill to edit, or click + to create one.</div>
          </div>
        )}
        {(creating || selected) && (
          <div
            className="flex flex-col gap-4"
            style={{ maxWidth: 720, margin: '0 auto' }}
            data-testid={creating ? 'skill-form-new' : `skill-form-${editing ?? ''}`}
          >
            <div className="flex items-center gap-2">
              <span className="text-lg font-semibold" style={{ color: 'var(--text-primary)' }}>
                {creating ? 'New skill' : (selected?.description || selected?.id || 'Skill')}
              </span>
            </div>

            <Row label="Id" htmlFor="skill-id" hint="Canonical id ([A-Za-z0-9_-]+). Editing it renames the skill (the old id is deleted).">
              <input
                id="skill-id"
                type="text"
                value={form.id ?? ''}
                onChange={(e) => setForm((f) => ({ ...f, id: e.target.value }))}
                style={inputStyle}
                placeholder="e.g. coding"
                autoComplete="off"
              />
            </Row>

            <Row label="Description" htmlFor="skill-description" hint="A short, human-readable label.">
              <input
                id="skill-description"
                type="text"
                value={form.description ?? ''}
                onChange={(e) => setForm((f) => ({ ...f, description: e.target.value }))}
                style={inputStyle}
                placeholder="e.g. Coding skill"
                autoComplete="off"
              />
            </Row>

            <Row label="Body" htmlFor="skill-body" hint="The skill's Markdown body. Injected into the agent's prompt on demand.">
              <textarea
                id="skill-body"
                value={form.body ?? ''}
                onChange={(e) => setForm((f) => ({ ...f, body: e.target.value }))}
                style={textareaStyle}
                placeholder="## Coding\n\nWrite code carefully…"
              />
            </Row>

            {formError && (
              <div
                data-testid="skill-form-error"
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
                  aria-label={creating ? 'Create skill' : 'Save skill'}
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
                    aria-label="Delete skill"
                  >
                    Delete
                  </button>
                )}
              </div>
              {!creating && selected && confirmingDelete === selected.id && (
                <div className="flex flex-col gap-2" data-testid="skill-delete-confirm">
                  <span className="text-sm" style={{ color: 'var(--needs-input)' }}>
                    Delete skill <strong>{selected.id}</strong>? This cannot be undone.
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