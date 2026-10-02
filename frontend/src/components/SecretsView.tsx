import { useEffect, useMemo, useRef, useState } from 'react'
import {
  createSecret,
  deleteSecret,
  updateSecret,
  useSecrets,
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

function Row({
  label, htmlFor, children, hint,
}: { label: string; htmlFor: string; children: React.ReactNode; hint?: React.ReactNode }) {
  return (
    <div style={{ display: 'grid', gridTemplateColumns: '140px 1fr', alignItems: 'start', gap: 12 }}>
      {htmlFor ? (
        <label htmlFor={htmlFor} style={labelStyle}>{label}</label>
      ) : (
        <span style={labelStyle}>{label}</span>
      )}
      <div>
        {children}
        {hint && (
          <div style={{ fontSize: 11, color: 'var(--text-faint)', marginTop: 4 }}>{hint}</div>
        )}
      </div>
    </div>
  )
}

// ── Component ───────────────────────────────────────────────────────────

/** The vault secrets CRUD view. Lists every secret key name on the left;
 *  the right pane is an editor (create or edit). Creating POSTs /api/secrets;
 *  editing PUTs /api/secrets/:name (upsert); the trash button DELETEs.
 *
 *  SECURITY: the list endpoint returns key NAMES only — never values. The
 *  value field is WRITE-ONLY: on create the operator types the new value;
 *  on edit the field is empty (paste a new value to overwrite — the stored
 *  value is never retrieved or displayed). The POST/PUT response never
 *  echoes the value back. */
export function SecretsView() {
  const { secrets, loaded, error, refresh } = useSecrets()

  const [editing, setEditing] = useState<string | null>(null)
  const [creating, setCreating] = useState(false)
  const [name, setName] = useState('')
  const [value, setValue] = useState('')
  const [showValue, setShowValue] = useState(false)
  const [submitting, setSubmitting] = useState(false)
  const [formError, setFormError] = useState<string | null>(null)
  const [confirmingDelete, setConfirmingDelete] = useState<string | null>(null)

  // Ref holding the latest `secrets` list so the seed effect can read it
  // without re-running on every poll tick.
  const secretsRef = useRef(secrets)
  secretsRef.current = secrets

  // Reset the form when the user picks a secret (or starts creating).
  // The value field is write-only — the stored value is never fetched.
  useEffect(() => {
    if (creating) {
      setName('')
      setValue('')
      setFormError(null)
      return
    }
    if (editing) {
      setName(editing)
      setValue('')
      setFormError(null)
      return
    }
    // Nothing selected — reset.
    setName('')
    setValue('')
  }, [editing, creating])

  const validateForm = (): string | null => {
    const trimmedName = name.trim()
    if (creating && trimmedName.length === 0) return 'name is required'
    if (creating && !/^[A-Za-z0-9_\-]+$/.test(trimmedName))
      return 'name must be [A-Za-z0-9_-]+ (no spaces, slashes, or dots)'
    if (value.trim().length === 0) return 'value must not be empty'
    return null
  }

  const handleSubmit = async () => {
    const verr = validateForm()
    if (verr) { setFormError(verr); return }
    setSubmitting(true)
    setFormError(null)
    const trimmedName = name.trim()
    if (creating) {
      const res = await createSecret({ name: trimmedName, value })
      setSubmitting(false)
      if (res.ok) {
        refresh()
        setCreating(false)
        setEditing(trimmedName)
      } else {
        setFormError(res.error)
      }
    } else if (editing) {
      const res = await updateSecret(editing, value)
      setSubmitting(false)
      if (res.ok) {
        refresh()
        setEditing(res.name)
      } else {
        setFormError(res.error)
      }
    }
  }

  const handleDelete = async (keyName: string) => {
    const ok = await deleteSecret(keyName)
    if (ok) {
      if (editing === keyName) setEditing(null)
      if (confirmingDelete === keyName) setConfirmingDelete(null)
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

  const selected = useMemo(
    () => (editing ? secrets.find((s) => s === editing) ?? null : null),
    [editing, secrets],
  )

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
            Secrets ({secrets.length})
          </span>
          <button
            type="button"
            className="btn btn-ghost flex items-center justify-center"
            style={{ width: 22, height: 22, padding: 0, fontSize: 14, lineHeight: 1 }}
            onClick={handleNew}
            aria-label="New secret"
            title="New secret"
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
          {loaded && error && (
            <div className="px-3 py-2 text-xs" style={{ color: 'var(--needs-input)' }}>
              Failed to load — the vault may be locked or unconfigured.
            </div>
          )}
          {loaded && !error && secrets.length === 0 && (
            <div className="px-3 py-2 text-xs" style={{ color: 'var(--text-faint)' }}>
              No secrets in the vault. Click &lsquo;New&rsquo; to add one.
            </div>
          )}
          {secrets.map((s) => {
            const isActive = (creating ? false : editing === s) && !confirmingDelete
            return (
              <div
                key={s}
                data-testid={`secret-row-${s}`}
                className={`agent-row px-3 py-2 cursor-pointer${isActive ? ' selected' : ''}`}
                onClick={() => {
                  if (confirmingDelete === s) setConfirmingDelete(null)
                  setCreating(false)
                  setEditing(s)
                }}
              >
                <div
                  className="text-sm truncate"
                  style={{ color: 'var(--text-primary)', letterSpacing: 'var(--tracking-tight)' }}
                  title={s}
                >
                  {s}
                </div>
              </div>
            )
          })}
        </div>
      </div>

      {/* Editor / detail pane */}
      <div className="flex-1 overflow-y-auto" style={{ padding: '24px 32px' }}>
        {error && !loaded && (
          <div
            data-testid="secrets-load-error"
            style={{ fontSize: 12, color: 'var(--needs-input)', marginBottom: 12 }}
          >
            Failed to load secrets — the vault may be locked or the backend unreachable.
          </div>
        )}
        {!creating && !selected && (
          <div
            className="flex flex-col items-center justify-center"
            style={{ height: '100%', color: 'var(--text-faint)', gap: 8 }}
          >
            <div className="text-sm">Select a secret to view/edit, or click + to create one.</div>
          </div>
        )}
        {(creating || selected) && (
          <div
            className="flex flex-col gap-4"
            style={{ maxWidth: 720, margin: '0 auto' }}
            data-testid={creating ? 'secret-form-new' : `secret-form-${editing ?? ''}`}
          >
            <div className="flex items-center gap-2">
              <span className="text-lg font-semibold" style={{ color: 'var(--text-primary)' }}>
                {creating ? 'New secret' : (editing ?? 'Secret')}
              </span>
            </div>

            <Row label="Name" htmlFor="secret-name" hint="The vault key name ([A-Za-z0-9_-]+). Stable — editing it is disabled.">
              <input
                id="secret-name"
                type="text"
                value={name}
                onChange={(e) => setName(e.target.value)}
                style={inputStyle}
                placeholder="e.g. API_KEY"
                autoComplete="off"
                disabled={!creating}
              />
            </Row>

            <Row
              label="Value"
              htmlFor="secret-value"
              hint={creating
                ? undefined
                : 'Paste a new value to overwrite (the stored value is never shown).'}
            >
              <div style={{ display: 'flex', gap: 8, alignItems: 'center' }}>
                <input
                  id="secret-value"
                  type={showValue ? 'text' : 'password'}
                  value={value}
                  onChange={(e) => setValue(e.target.value)}
                  style={inputStyle}
                  placeholder={creating ? 'Enter the secret value' : 'Paste new value to overwrite'}
                  autoComplete="off"
                />
                <button
                  type="button"
                  className="btn btn-ghost"
                  style={{ flexShrink: 0, padding: '4px 8px', fontSize: 12 }}
                  onClick={() => setShowValue((v) => !v)}
                  title={showValue ? 'Hide value' : 'Show value'}
                >
                  {showValue ? 'Hide' : 'Show'}
                </button>
              </div>
            </Row>

            {formError && (
              <div
                data-testid="secret-form-error"
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
                  aria-label={creating ? 'Create secret' : 'Save secret'}
                  data-testid="secret-save"
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
                {!creating && selected && confirmingDelete !== editing && (
                  <button
                    type="button"
                    className="btn btn-danger-ghost px-3 py-2 rounded-lg text-sm font-medium"
                    style={{ marginLeft: 'auto' }}
                    onClick={() => setConfirmingDelete(editing)}
                    aria-label="Delete secret"
                    data-testid="secret-delete"
                  >
                    Delete
                  </button>
                )}
              </div>
              {!creating && selected && confirmingDelete === editing && (
                <div className="flex flex-col gap-2" data-testid="secret-delete-confirm">
                  <span className="text-sm" style={{ color: 'var(--needs-input)' }}>
                    Delete secret <strong>{editing}</strong>? This cannot be undone.
                  </span>
                  <div className="flex gap-2">
                    <button
                      type="button"
                      className="btn btn-danger-ghost px-3 py-2 rounded-lg text-sm font-medium"
                      style={{ background: 'var(--needs-input)', color: 'var(--text-primary)' }}
                      onClick={() => void handleDelete(editing!)}
                      aria-label="Confirm delete"
                      data-testid="secret-delete-confirm"
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
