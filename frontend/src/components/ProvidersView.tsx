import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import type { ProviderInput, ProviderAuthStatus } from '../types'
import {
  createProvider,
  deleteProvider,
  fetchDefaultProvider,
  setDefaultProvider,
  updateProvider,
  useAllProviders,
} from '../hooks/useApi'

// ── Helpers ─────────────────────────────────────────────────────────────

const AUTH_STATUS_LABELS: Record<ProviderAuthStatus, string> = {
  'api-key': 'API Key',
  'oauth': 'OAuth',
  'keyless': 'Keyless',
  'none': 'Not Configured',
  'vault-locked': 'Vault Locked',
}

const PROVIDER_LABELS: Record<string, string> = {
  anthropic: 'Anthropic',
  ollama: 'Ollama',
  'openai-compat': 'OpenAI-compatible',
}

/** Prefer the backend's display name; fall back to the local map, then the id. */
function providerLabelOf(name: string, displayName?: string): string {
  return displayName || PROVIDER_LABELS[name] || name
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

/** The empty-form defaults for "New provider". */
function emptyInput(): ProviderInput {
  return { name: '', api_key: '', base_url: '', default_model: '' }
}

/** Auth status badge color. */
function authBadgeColor(status: ProviderAuthStatus): string {
  switch (status) {
    case 'api-key': return 'var(--text-faint)'
    case 'oauth': return 'var(--text-faint)'
    case 'keyless': return 'var(--text-faint)'
    case 'none': return 'var(--text-faint)'
    case 'vault-locked': return 'var(--needs-input)'
  }
}

// ── Component ───────────────────────────────────────────────────────────

/** The Providers CRUD view. Lists every configured provider on the left; the
 *  right pane is an editor (create or edit). Creating POSTs /api/providers;
 *  editing PUTs /api/providers/:name; the trash button DELETEs. The
 *  "Set as default" / "Clear default" button calls PUT /api/providers/default.
 *
 *  SECURITY: the API key field is write-only (type="password"), never
 *  pre-filled. The stored key is never retrieved or displayed. */
export function ProvidersView() {
  const { providers, loaded, error, refresh } = useAllProviders()

  // The configured default provider (re-fetched after every mutation).
  const [defaultProvider, setDefaultProv] = useState<string | null>(null)
  const refreshDefault = useCallback(async () => {
    setDefaultProv(await fetchDefaultProvider())
  }, [])
  useEffect(() => { void refreshDefault() }, [refreshDefault])

  const [editing, setEditing] = useState<string | null>(null)
  const [creating, setCreating] = useState(false)
  const [form, setForm] = useState<ProviderInput>(emptyInput())
  const [submitting, setSubmitting] = useState(false)
  const [formError, setFormError] = useState<string | null>(null)
  const [formErrorField, setFormErrorField] = useState<string | null>(null)
  const [confirmingDelete, setConfirmingDelete] = useState<string | null>(null)
  const [settingDefault, setSettingDefault] = useState(false)

  // Ref holding the latest `providers` list so the seed effect can read it
  // without re-running on every poll tick.
  const providersRef = useRef(providers)
  providersRef.current = providers

  // When the user picks a provider to edit (or starts creating), seed the form.
  useEffect(() => {
    if (creating) {
      setForm(emptyInput())
      setFormError(null)
      return
    }
    if (editing) {
      const p = providersRef.current.find((pr) => pr.name === editing)
      if (p) {
        setForm({
          name: p.name,
          api_key: '',
          base_url: p.baseUrl ?? '',
          default_model: p.defaultModel ?? '',
        })
        setFormError(null)
      }
    }
  }, [editing, creating])

  const selected = useMemo(
    () => (editing ? providers.find((p) => p.name === editing) ?? null : null),
    [editing, providers],
  )

  // Unconfigured providers available for the "New provider" dropdown.
  const unconfigured = useMemo(
    () => providers.filter((p) => p.authStatus === 'none'),
    [providers],
  )

  // Only configured providers appear in the list. The full set still feeds
  // the "New provider" dropdown so unconfigured ones can be set up. Providers
  // in a locked vault stay visible so the user can see why they're unusable.
  const configured = useMemo(
    () => providers.filter((p) => p.authStatus !== 'none'),
    [providers],
  )

  const handleSubmit = async () => {
    setSubmitting(true)
    setFormError(null)
    setFormErrorField(null)
    const trimmedName = (form.name ?? '').trim()
    if (creating) {
      const payload: ProviderInput = {
        name: trimmedName,
        api_key: form.api_key && form.api_key.trim().length > 0 ? form.api_key.trim() : undefined,
        base_url: form.base_url && form.base_url.trim().length > 0 ? form.base_url.trim() : undefined,
        default_model: form.default_model && form.default_model.trim().length > 0 ? form.default_model.trim() : undefined,
      }
      const res = await createProvider(payload)
      setSubmitting(false)
      if (res.ok) {
        refresh()
        setCreating(false)
        setEditing(res.provider.name)
      } else {
        setFormError(res.error)
        setFormErrorField(res.field ?? null)
      }
    } else if (editing) {
      const payload: ProviderInput = {
        api_key: form.api_key && form.api_key.trim().length > 0 ? form.api_key.trim() : undefined,
        base_url: form.base_url && form.base_url.trim().length > 0 ? form.base_url.trim() : undefined,
        default_model: form.default_model && form.default_model.trim().length > 0 ? form.default_model.trim() : undefined,
      }
      const res = await updateProvider(editing, payload)
      setSubmitting(false)
      if (res.ok) {
        refresh()
        setEditing(res.provider.name)
      } else {
        setFormError(res.error)
        setFormErrorField(res.field ?? null)
      }
    }
  }

  const handleDelete = async (name: string) => {
    const ok = await deleteProvider(name)
    if (ok) {
      if (editing === name) setEditing(null)
      if (confirmingDelete === name) setConfirmingDelete(null)
      refresh()
      await refreshDefault()
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

  const handleSelectProvider = (name: string) => {
    if (confirmingDelete === name) setConfirmingDelete(null)
    setCreating(false)
    setEditing(name)
  }

  // In create mode there is no `selected` row yet: resolve the flags from the
  // /api/providers/all entry matching the picked provider name.
  const effective = useMemo(() => {
    if (selected) return selected
    if (creating && form.name) return providers.find((p) => p.name === form.name) ?? null
    return null
  }, [selected, creating, form.name, providers])

  const isVaultLocked = effective?.authStatus === 'vault-locked'
  const baseUrlRequired = effective?.baseUrlRequired ?? false
  const baseUrlEditable = effective?.baseUrlEditable ?? true
  const keyOptional = effective?.keyOptional ?? false
  const defaultModelRequired = effective?.defaultModelRequired ?? false

  // A required field with no value blocks Save (whitespace counts as empty).
  const missingRequired =
    (baseUrlRequired && !(form.base_url ?? '').trim()) ||
    (defaultModelRequired && !(form.default_model ?? '').trim())

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
            Providers ({configured.length})
          </span>
          <button
            type="button"
            className="btn btn-ghost flex items-center justify-center"
            style={{ width: 22, height: 22, padding: 0, fontSize: 14, lineHeight: 1 }}
            onClick={handleNew}
            aria-label="New provider"
            title="New provider"
            data-testid="provider-new-btn"
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
              Failed to load — the backend may be unreachable.
            </div>
          )}
          {loaded && !error && configured.length === 0 && (
            <div className="px-3 py-2 text-xs" style={{ color: 'var(--text-faint)' }}>
              No providers configured.
            </div>
          )}
          {configured.map((p) => {
            const isActive = (creating ? false : editing === p.name) && !confirmingDelete
            return (
              <div
                key={p.name}
                data-testid={`provider-row-${p.name}`}
                className={`agent-row px-3 py-2 cursor-pointer${isActive ? ' selected' : ''}`}
                onClick={() => handleSelectProvider(p.name)}
              >
                <div className="flex items-center gap-2">
                  <span
                    className="text-sm truncate mr-auto"
                    style={{ color: 'var(--text-primary)', letterSpacing: 'var(--tracking-tight)' }}
                  >
                    {providerLabelOf(p.name, p.displayName)}
                  </span>
                  {defaultProvider === p.name && (
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
                  style={{ color: authBadgeColor(p.authStatus) }}
                >
                  {AUTH_STATUS_LABELS[p.authStatus]}
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
            data-testid="providers-load-error"
            style={{ fontSize: 12, color: 'var(--needs-input)', marginBottom: 12 }}
          >
            Failed to load providers — the backend may be unreachable.
          </div>
        )}
        {!creating && !selected && (
          <div
            className="flex flex-col items-center justify-center"
            style={{ height: '100%', color: 'var(--text-faint)', gap: 8 }}
          >
            <div className="text-sm">Select a provider to edit, or click + to add one.</div>
          </div>
        )}
        {(creating || selected) && (
          <div
            className="flex flex-col gap-4"
            style={{ maxWidth: 640, margin: '0 auto' }}
            data-testid={creating ? 'provider-form-new' : `provider-form-${editing ?? ''}`}
          >
            <div className="flex items-center gap-2">
              <span className="text-lg font-semibold" style={{ color: 'var(--text-primary)' }}>
                {creating ? 'New provider' : providerLabelOf(selected?.name ?? '', selected?.displayName)}
              </span>
              {defaultProvider === selected?.name && (
                <span
                  className="pill"
                  style={{ background: 'var(--bg-elevated)', color: 'var(--text-faint)', fontSize: 11, padding: '0 6px' }}
                >
                  default
                </span>
              )}
              {selected && (
                <span
                  className="pill"
                  style={{
                    background: 'var(--bg-elevated)',
                    color: authBadgeColor(selected.authStatus),
                    fontSize: 11,
                    padding: '0 6px',
                  }}
                >
                  {AUTH_STATUS_LABELS[selected.authStatus]}
                </span>
              )}
            </div>

            {creating && (
              <Row label="Provider" htmlFor="provider-name" hint="Select a provider to configure.">
                <select
                  id="provider-name"
                  value={form.name ?? ''}
                  onChange={(e) => setForm((f) => ({ ...f, name: e.target.value }))}
                  className="composer-select"
                  style={inputStyle}
                >
                  <option value="">(select)</option>
                  {unconfigured.map((p) => (
                    <option key={p.name} value={p.name}>
                      {providerLabelOf(p.name, p.displayName)}
                    </option>
                  ))}
                  {/* Allow already-configured providers too (upsert) */}
                  {configured.map((p) => (
                    <option key={p.name} value={p.name}>
                      {providerLabelOf(p.name, p.displayName)} (reconfigure)
                    </option>
                  ))}
                </select>
              </Row>
            )}

            <Row
              label="API key"
              htmlFor="provider-api-key"
              hint={creating
                ? 'Stored in the vault — never persisted in cleartext. Leave blank for a keyless endpoint.'
                : keyOptional
                  ? 'Optional — leave blank for a keyless endpoint.'
                  : isVaultLocked
                    ? 'Vault is locked — unlock it to manage API keys.'
                    : 'Paste a new key to rotate (the stored key is never shown).'}
            >
              <input
                id="provider-api-key"
                type="password"
                value={form.api_key ?? ''}
                onChange={(e) => setForm((f) => ({ ...f, api_key: e.target.value }))}
                style={inputStyle}
                placeholder={keyOptional ? '(optional — keyless endpoint)' : 'Enter API key'}
                autoComplete="off"
                disabled={isVaultLocked}
                aria-invalid={formErrorField === 'api_key'}
                data-testid="provider-api-key-input"
              />
              {formErrorField === 'api_key' && formError && (
                <div style={{ fontSize: 12, color: 'var(--needs-input)', marginTop: 4 }}>
                  {formError}
                </div>
              )}
            </Row>

            <Row
              label={baseUrlRequired ? 'Base URL *' : 'Base URL'}
              htmlFor="provider-base-url"
              hint={baseUrlRequired
                ? 'Required — the full URL including the API path, e.g. https://host/v1.'
                : effective?.defaultBaseUrl
                  ? `Fixed default: ${effective.defaultBaseUrl}`
                  : 'Custom API endpoint URL (optional).'}
            >
              <input
                id="provider-base-url"
                type="text"
                value={baseUrlEditable ? (form.base_url ?? '') : (effective?.baseUrl ?? effective?.defaultBaseUrl ?? '')}
                onChange={(e) => setForm((f) => ({ ...f, base_url: e.target.value }))}
                style={baseUrlEditable ? inputStyle : { ...inputStyle, opacity: 0.7 }}
                placeholder={effective?.defaultBaseUrl ?? (baseUrlRequired ? 'https://host/v1' : '(optional)')}
                autoComplete="off"
                readOnly={!baseUrlEditable}
                aria-required={baseUrlRequired}
                aria-invalid={formErrorField === 'base_url'}
                data-testid="provider-base-url-input"
              />
              {formErrorField === 'base_url' && formError && (
                <div style={{ fontSize: 12, color: 'var(--needs-input)', marginTop: 4 }}>
                  {formError}
                </div>
              )}
            </Row>

            <Row
              label={defaultModelRequired ? 'Default model *' : 'Default model'}
              htmlFor="provider-default-model"
              hint={defaultModelRequired
                ? 'Required — the model id your endpoint serves.'
                : 'Provider-specific model id. Leave blank to use the provider default.'}
            >
              <input
                id="provider-default-model"
                type="text"
                value={form.default_model ?? ''}
                onChange={(e) => setForm((f) => ({ ...f, default_model: e.target.value }))}
                style={inputStyle}
                placeholder={defaultModelRequired ? 'e.g. qwen2.5-7b-instruct' : 'e.g. claude-sonnet-4-20250514'}
                autoComplete="off"
                aria-required={defaultModelRequired}
                aria-invalid={formErrorField === 'default_model'}
                data-testid="provider-default-model-input"
              />
              {formErrorField === 'default_model' && formError && (
                <div style={{ fontSize: 12, color: 'var(--needs-input)', marginTop: 4 }}>
                  {formError}
                </div>
              )}
            </Row>

            {formError && !formErrorField && (
              <div
                data-testid="provider-form-error"
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
                  disabled={submitting || (creating && !(form.name ?? '').trim()) || missingRequired}
                  aria-label={creating ? 'Create provider' : 'Save provider'}
                  data-testid="provider-save"
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
                {!creating && selected && confirmingDelete !== selected.name && (
                  <button
                    type="button"
                    className="btn btn-ghost px-3 py-2 rounded-lg text-sm font-medium"
                    disabled={settingDefault}
                    aria-label={defaultProvider === selected.name ? 'Clear default provider' : 'Set as default provider'}
                    title={defaultProvider === selected.name ? 'Clear default' : 'Set as default'}
                    onClick={async () => {
                      setSettingDefault(true)
                      const target = defaultProvider === selected.name ? null : selected.name
                      const ok = await setDefaultProvider(target)
                      setSettingDefault(false)
                      if (ok) {
                        await refreshDefault()
                        refresh()
                      } else {
                        setFormError('Could not change the default — the backend may be unreachable.')
                      }
                    }}
                    data-testid={defaultProvider === selected.name ? 'clear-default-provider' : 'set-default-provider'}
                  >
                    {defaultProvider === selected.name ? 'Clear default' : 'Set as default'}
                  </button>
                )}
                {!creating && selected && confirmingDelete !== selected.name && (
                  <button
                    type="button"
                    className="btn btn-danger-ghost px-3 py-2 rounded-lg text-sm font-medium"
                    style={{ marginLeft: 'auto' }}
                    onClick={() => setConfirmingDelete(selected.name)}
                    aria-label="Delete provider"
                    data-testid="provider-delete"
                  >
                    Delete
                  </button>
                )}
              </div>
              {!creating && selected && confirmingDelete === selected.name && (
                <div className="flex flex-col gap-2" data-testid="provider-delete-confirm">
                  <span className="text-sm" style={{ color: 'var(--needs-input)' }}>
                    Delete provider <strong>{selected.name}</strong>? This removes the vault credential and cannot be undone.
                  </span>
                  <div className="flex gap-2">
                    <button
                      type="button"
                      className="btn btn-danger-ghost px-3 py-2 rounded-lg text-sm font-medium"
                      style={{ background: 'var(--needs-input)', color: 'var(--text-primary)' }}
                      onClick={() => void handleDelete(selected.name)}
                      aria-label="Confirm delete"
                      data-testid="provider-delete-confirm-btn"
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