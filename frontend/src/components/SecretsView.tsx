import { useEffect, useMemo, useRef, useState } from 'react'
import {
  createSecret,
  deleteSecret,
  fetchSecretValue,
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
 *  value is shown in the editor when an existing secret is selected (fetched
 *  on demand via GET /api/secrets/:name). The value field is a password
 *  input by default with a show/hide toggle. The POST/PUT response never
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
  const [valueLoaded, setValueLoaded] = useState(false)
  const [valueError, setValueError] = useState<string | null>(null)

  // Ref holding the latest `secrets` list so the seed effect can read it
  // without re-running on every poll tick.
  const secretsRef = useRef(secrets)
  secretsRef.current = secrets

  // Fetch the secret value when the user selects an existing secret to edit.
  // The list endpoint returns only key names; the value is fetched on demand.
  useEffect(() => {
    if (creating) {
      setName('')
      setValue('')
      setFormError(null)
      setValueLoaded(true)
      setValueError(null)
      return
    }
    if (editing) {
      setName(editing)
      setValue('')
      setValueLoaded(false)
      setValueError(null)
      setFormError(null)
      let cancelled = false
      void (async () => {
        const detail = await fetchSecretValue(editing)
        if (cancelled) return
        if (detail) {
          setValue(detail.value)
          setValueLoaded(true)
        } else {
          setValueError('Failed to load secret value — the vault may be locked or the key absent.')
          setValueLoaded(true)
        }
      })()
      return () => { cancelled = true }
    }
    // Nothing selected — reset.
    setName('')
    setValue('')
    setValueLoaded(false)
    setValueError(null)
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
                : 'Edit the value to update the secret (upsert).'}
            >
              <div style={{ display: 'flex', gap: 8, alignItems: 'center' }}>
                <input
                  id="secret-value"
                  type={showValue ? 'text' : 'password'}
                  value={value}
                  onChange={(e) => setValue(e.target.value)}
                  style={inputStyle}
                  placeholder={valueLoaded ? '' : 'Loading…'}
                  autoComplete="off"
                  disabled={!valueLoaded || !creating && !selected}
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
              {valueError && (
                <div style={{ fontSize: 11, color: 'var(--needs-input)', marginTop: 4 }}>
                  {valueError}
                </div>
              )}
            </Row>

            {formError && (
              <div
                data-testid="secret-form-error"
                style={{ fontSize: 12, color: 'var(--needs-input)' }}
              >
                {formError}
              </div>
            )}

            <div className="flex items-center gap-2" style={{ marginTop: 8 }}>
              <button
                type="button"
                className="btn btn-primary"
                onClick={handleSubmit}
                disabled={submitting || !valueLoaded}
                data-testid="secret-save"
              >
                {submitting ? 'Saving…' : creating ? 'Create' : 'Save'}
              </button>
              <button
                type="button"
                className="btn btn-ghost"
                onClick={handleCancel}
              >
                Cancel
              </button>
              {!creating && selected && (
                <>
                  <div style={{ flex: 1 }} />
                  {confirmingDelete === editing ? (
                    <div className="flex items-center gap-2">
                      <span className="text-xs" style={{ color: 'var(--needs-input)' }}>
                        Delete &ldquo;{editing}&rdquo;? This cannot be undone.
                      </span>
                      <button
                        type="button"
                        className="btn"
                        style={{ background: 'var(--needs-input)', color: 'white', fontSize: 12 }}
                        onClick={() => void handleDelete(editing!)}
                        data-testid="secret-delete-confirm"
                      >
                        Delete
                      </button>
                      <button
                        type="button"
                        className="btn btn-ghost"
                        style={{ fontSize: 12 }}
                        onClick={() => setConfirmingDelete(null)}
                      >
                        Keep
                      </button>
                    </div>
                  ) : (
                    <button
                      type="button"
                      className="btn btn-ghost"
                      style={{ color: 'var(--needs-input)', fontSize: 12 }}
                      onClick={() => setConfirmingDelete(editing)}
                      aria-label="Delete secret"
                      data-testid="secret-delete"
                    >
                      Delete
                    </button>
                  )}
                </>
              )}
            </div>
          </div>
        )}
      </div>
    </div>
  )
}
