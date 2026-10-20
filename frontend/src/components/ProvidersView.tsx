import { useCallback, useEffect, useMemo, useState } from 'react'
import type { ProviderDetail, ProviderInput, ProviderAuthStatus } from '../types'
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
  openai: 'OpenAI API',
  openrouter: 'OpenRouter',
}

const NAME_RULE =
  'instance names are 1–32 characters of a–z, 0–9 and “-” (no leading/trailing “-”); e.g. local-vllm'

/** The backend's provider-name grammar, mirrored for inline validation. */
const NAME_RE = /^[a-z0-9]+(?:-[a-z0-9]+)*$/
const RESERVED_NAMES = ['all', 'default']

function typeLabelOf(p: ProviderDetail): string {
  return p.typeDisplayName || (p.type ? PROVIDER_LABELS[p.type] : undefined) || p.displayName || p.name
}

/** Should this instance be listed in the left pane?
 *
 *  Hidden: an instance that is not configured — no credential and no usable
 *  endpoint. It only clutters the list, and it stays reachable through the
 *  type picker, so the user can still (re-)configure it.
 *
 *  Kept: a configured instance, an instance whose vault is locked (its
 *  credential may well exist — we just cannot read it right now, and the row
 *  must stay reachable so the key can be rotated), and a problem row (the
 *  only way to fix or delete a broken config section). */
function isListedInList(p: ProviderDetail): boolean {
  if (p.problem) return true
  // `configured` is absent on older payloads — treat it as configured.
  if (p.configured !== false) return true
  return p.authStatus !== 'none'
}

/** "<name> — <type>" for explicit instances, else just the type label. */
function instanceLabel(p: ProviderDetail): string {
  return p.type && p.name !== p.type ? `${p.name} — ${typeLabelOf(p)}` : typeLabelOf(p)
}

/** Returns a human error, or null when the name is valid for the type. */
function validateName(name: string, ownType: string, typeIds: string[]): string | null {
  if (!name) return 'an instance name is required'
  if (name.length > 32 || !NAME_RE.test(name)) return NAME_RULE
  if (RESERVED_NAMES.includes(name)) {
    return `“${name}” is reserved — choose another name (e.g. ${name}-2)`
  }
  if (typeIds.includes(name) && name !== ownType) {
    return `“${name}” is a provider type id — choose another name, e.g. ${name}-personal`
  }
  return null
}

/** The vault key name(s) the delete dialog names. Server-supplied (so it cannot
 *  drift); falls back to the derived name for older payloads/mocks. */
function keyNamesOf(p: ProviderDetail): string {
  const names = [p.apiKeyName, p.oauthKeyName].filter((k): k is string => !!k)
  return names.length > 0
    ? names.join(' and ')
    : `PROVIDER_APIKEY_${p.name.toUpperCase().replace(/-/g, '_')}`
}

/** A note when the key name is vendor-conventional and may be shared. */
function sharedKeyNote(p: ProviderDetail): string {
  return p.apiKeyName === 'OPENAI_API_KEY' || p.apiKeyName === 'OPENROUTER_API_KEY'
    ? ' (this name may be shared with other tooling)'
    : ''
}

/** The delete-confirmation copy for a row's class (design §10.6). */
function deleteConfirmText(p: ProviderDetail, isDefault: boolean): string {
  const defClause = isDefault ? ', clears it as default' : ''
  if (p.problem) {
    return `Delete ${p.name}? This removes the config.toml section. Its provider`
      + ` type is unknown, so any credential stored for it must be deleted`
      + ` manually (/vault delete ${p.name}).`
  }
  const keys = keyNamesOf(p) + sharedKeyNote(p)
  if (p.name === p.type) {
    // A type-named instance keeps its (implicit) row after the delete, but
    // whether it still works depends on whether it needed a credential at
    // all: a keyless endpoint (local Ollama) keeps working, one that needs a
    // key does not — it drops out of the list until it is re-configured.
    if (p.keyOptional) {
      return `Delete ${p.name} (${typeLabelOf(p)})? This removes ${keys} from the`
        + ` vault${defClause}. The ${typeLabelOf(p)} instance needs no API key,`
        + ` so it keeps working.`
    }
    return `Delete ${p.name} (${typeLabelOf(p)})? This removes ${keys} from the`
      + ` vault${defClause}. The ${typeLabelOf(p)} instance is no longer`
      + ` configured — re-configure it from the type picker if you need it.`
  }
  return `Delete ${p.name} (${typeLabelOf(p)})? This removes ${keys} from the`
    + ` vault${defClause}, and sessions or agent defs using “${p.name}” will`
    + ` fail until you re-create it or point them elsewhere.`
}

function nonEmpty(s: string | undefined): string | undefined {
  const t = (s ?? '').trim()
  return t.length > 0 ? t : undefined
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

function authBadgeColor(status: ProviderAuthStatus): string {
  switch (status) {
    case 'vault-locked': return 'var(--needs-input)'
    default: return 'var(--text-faint)'
  }
}

// ── Component ───────────────────────────────────────────────────────────

type Mode = 'idle' | 'create' | 'edit'

interface FormState {
  type: string
  name: string
  api_key: string
  base_url: string
  default_model: string
}

const emptyForm = (type: string, name: string): FormState =>
  ({ type, name, api_key: '', base_url: '', default_model: '' })

/** The Providers CRUD view. Lists every provider *instance* (implicit and
 *  explicit, including problem rows); the right pane is an editor.
 *
 *  Creating: pick a type, then a name (prefilled with the type id, inline
 *  validation), then the type's flag-driven fields. Editing: name and type are
 *  read-only; the rest is editable. Problem rows are delete-only.
 *
 *  SECURITY: the API key field is write-only (type="password"), never
 *  pre-filled. The stored key is never retrieved or displayed. */
export function ProvidersView() {
  const { providers, loaded, error, refresh } = useAllProviders()

  // The left pane lists only the instances worth showing: the configured
  // ones, plus the ones the user must still be able to act on (a locked
  // vault, a broken section). Unconfigured instances are configured from the
  // type picker instead.
  const listedProviders = useMemo(
    () => providers.filter(isListedInList),
    [providers],
  )

  const [defaultProvider, setDefaultProv] = useState<string | null>(null)
  const refreshDefault = useCallback(async () => {
    setDefaultProv(await fetchDefaultProvider())
  }, [])
  useEffect(() => { void refreshDefault() }, [refreshDefault])

  const [mode, setMode] = useState<Mode>('idle')
  const [editName, setEditName] = useState<string | null>(null)
  const [form, setForm] = useState<FormState>(emptyForm('', ''))
  const [submitting, setSubmitting] = useState(false)
  const [formError, setFormError] = useState<string | null>(null)
  const [formErrorField, setFormErrorField] = useState<string | null>(null)
  const [confirmingDelete, setConfirmingDelete] = useState<string | null>(null)
  const [settingDefault, setSettingDefault] = useState(false)

  // The type catalog: one row per type, named after its own type id.
  const typeCatalog = useMemo(
    () => providers.filter((p) => p.type != null && p.name === p.type),
    [providers],
  )
  const typeIds = useMemo(
    () => typeCatalog.map((p) => p.type!).filter(Boolean),
    [typeCatalog],
  )

  const selected = useMemo(
    () => (mode === 'edit' && editName ? providers.find((p) => p.name === editName) ?? null : null),
    [mode, editName, providers],
  )

  // The row that supplies the flags/base URL: the type row in create mode, the
  // selected instance in edit mode.
  const flags = mode === 'create'
    ? typeCatalog.find((p) => p.type === form.type) ?? null
    : selected

  const handleNew = () => {
    const first = typeCatalog[0]
    setMode('create')
    setEditName(null)
    setForm(emptyForm(first?.type ?? '', first?.type ?? ''))
    setFormError(null)
    setFormErrorField(null)
    setConfirmingDelete(null)
  }

  const handleSelect = (name: string) => {
    const p = providers.find((x) => x.name === name)
    if (!p) return
    setMode('edit')
    setEditName(name)
    setConfirmingDelete(null)
    setForm({
      type: p.type ?? '',
      name: p.name,
      api_key: '',
      base_url: p.baseUrl ?? '',
      default_model: p.defaultModel ?? '',
    })
    setFormError(null)
    setFormErrorField(null)
  }

  const handleCancel = () => {
    setMode('idle')
    setEditName(null)
    setFormError(null)
    setFormErrorField(null)
    setConfirmingDelete(null)
  }

  const onTypeChange = (typeId: string) =>
    setForm((f) => ({ ...f, type: typeId, name: typeId }))

  const nameErr = mode === 'create' ? validateName(form.name, form.type, typeIds) : null

  const isVaultLocked = flags?.authStatus === 'vault-locked'
  const baseUrlRequired = flags?.baseUrlRequired ?? false
  const baseUrlEditable = flags?.baseUrlEditable ?? true
  const keyOptional = flags?.keyOptional ?? false
  const defaultModelRequired = flags?.defaultModelRequired ?? false
  const missingRequired =
    (baseUrlRequired && !(form.base_url ?? '').trim()) ||
    (defaultModelRequired && !(form.default_model ?? '').trim())
  const reconfiguring =
    mode === 'create' && providers.some((p) => p.name === form.name && p.reconfiguring === true)
  const canSubmit = mode === 'edit' && selected?.problem
    ? false
    : (nameErr == null && !missingRequired && !submitting)

  const submitLabel = mode === 'create'
    ? (reconfiguring ? 'Reconfigure' : 'Configure')
    : 'Save'

  // The value shown in a read-only base-URL field (fixed endpoints).
  const fixedBaseValue = flags?.baseUrl ?? flags?.defaultBaseUrl ?? ''

  const handleSubmit = async () => {
    setFormError(null)
    setFormErrorField(null)
    if (mode === 'create') {
      if (nameErr) return
      setSubmitting(true)
      const payload: ProviderInput = {
        type: form.type,
        name: form.name.trim(),
        api_key: nonEmpty(form.api_key),
        base_url: baseUrlEditable ? nonEmpty(form.base_url) : undefined,
        default_model: nonEmpty(form.default_model),
      }
      const res = await createProvider(payload)
      setSubmitting(false)
      if (res.ok) {
        refresh()
        await refreshDefault()
        setMode('edit')
        setEditName(res.provider.name)
      } else {
        setFormError(res.error)
        setFormErrorField(res.field ?? null)
      }
    } else if (mode === 'edit' && selected) {
      setSubmitting(true)
      const payload: ProviderInput = {
        api_key: nonEmpty(form.api_key),
        base_url: baseUrlEditable ? nonEmpty(form.base_url) : undefined,
        default_model: nonEmpty(form.default_model),
      }
      const res = await updateProvider(selected.name, payload)
      setSubmitting(false)
      if (res.ok) {
        refresh()
        await refreshDefault()
      } else {
        setFormError(res.error)
        setFormErrorField(res.field ?? null)
      }
    }
  }

  const handleDelete = async (name: string) => {
    const ok = await deleteProvider(name)
    if (ok) {
      if (editName === name) handleCancel()
      if (confirmingDelete === name) setConfirmingDelete(null)
      refresh()
      await refreshDefault()
    }
  }

  // ── Render ──────────────────────────────────────────────────────────
  const showingForm = mode !== 'idle'

  return (
    <div className="flex flex-1 min-h-0" style={{ background: 'var(--bg-base)' }}>
      {/* List pane */}
      <div
        className="shrink-0 flex flex-col"
        style={{ width: 280, background: 'var(--bg-surface)', borderRight: '1px solid var(--border)' }}
      >
        <div
          className="flex items-center justify-between px-3 py-2"
          style={{ borderBottom: '1px solid var(--border)' }}
        >
          <span
            className="text-xs font-semibold uppercase"
            style={{ color: 'var(--text-muted)', letterSpacing: '0.08em' }}
          >
            Providers ({listedProviders.length})
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
            <div className="px-3 py-2 text-xs" style={{ color: 'var(--text-faint)' }}>Loading…</div>
          )}
          {loaded && error && (
            <div className="px-3 py-2 text-xs" style={{ color: 'var(--needs-input)' }}>
              Failed to load — the backend may be unreachable.
            </div>
          )}
          {loaded && !error && listedProviders.length === 0 && (
            <div className="px-3 py-2 text-xs" style={{ color: 'var(--text-faint)' }}>
              {providers.length === 0
                ? 'No providers configured.'
                : 'No provider is configured yet — add one from the type picker.'}
            </div>
          )}
          {listedProviders.map((p) => {
            const isActive = mode === 'edit' && editName === p.name && confirmingDelete !== p.name
            return (
              <div
                key={p.name}
                data-testid={`provider-row-${p.name}`}
                className={`agent-row px-3 py-2 cursor-pointer${isActive ? ' selected' : ''}`}
                onClick={() => handleSelect(p.name)}
              >
                <div className="flex items-center gap-2">
                  <span
                    className="text-sm truncate mr-auto"
                    style={{ color: 'var(--text-primary)', letterSpacing: 'var(--tracking-tight)' }}
                  >
                    {instanceLabel(p)}
                  </span>
                  {defaultProvider === p.name && (
                    <span
                      className="pill"
                      style={{ background: 'var(--bg-elevated)', color: 'var(--text-faint)', padding: '0 0.4em', fontSize: '0.7em' }}
                    >
                      default
                    </span>
                  )}
                </div>
                {p.problem ? (
                  <div className="text-xs mt-0.5 truncate" style={{ color: 'var(--needs-input)' }} title={p.problem}>
                    {p.problem}
                  </div>
                ) : (
                  <div className="text-xs mt-0.5 truncate" style={{ color: authBadgeColor(p.authStatus) }}>
                    {AUTH_STATUS_LABELS[p.authStatus]}
                  </div>
                )}
              </div>
            )
          })}
        </div>
      </div>

      {/* Editor / detail pane */}
      <div className="flex-1 overflow-y-auto" style={{ padding: '24px 32px' }}>
        {error && !loaded && (
          <div data-testid="providers-load-error" style={{ fontSize: 12, color: 'var(--needs-input)', marginBottom: 12 }}>
            Failed to load providers — the backend may be unreachable.
          </div>
        )}
        {!showingForm && (
          <div className="flex flex-col items-center justify-center" style={{ height: '100%', color: 'var(--text-faint)', gap: 8 }}>
            <div className="text-sm">Select a provider to edit, or click + to add one.</div>
          </div>
        )}
        {mode === 'create' && (
          <div
            className="flex flex-col gap-4"
            style={{ maxWidth: 640, margin: '0 auto' }}
            data-testid="provider-form-new"
          >
            <span className="text-lg font-semibold" style={{ color: 'var(--text-primary)' }}>New provider</span>

            <Row label="Type" htmlFor="provider-type" hint="The kind of API this instance speaks.">
              <select
                id="provider-type"
                data-testid="provider-type-select"
                value={form.type}
                onChange={(e) => onTypeChange(e.target.value)}
                className="composer-select"
                style={inputStyle}
              >
                {typeCatalog.map((t) => (
                  <option key={t.type!} value={t.type!}>{typeLabelOf(t)}</option>
                ))}
              </select>
            </Row>

            <Row label="Unique Name" htmlFor="provider-name" hint={NAME_RULE}>
              <input
                id="provider-name"
                data-testid="provider-name-input"
                type="text"
                value={form.name}
                onChange={(e) => setForm((f) => ({ ...f, name: e.target.value }))}
                style={inputStyle}
                autoComplete="off"
                aria-invalid={nameErr != undefined}
                aria-describedby={nameErr != undefined ? 'provider-name-error' : undefined}
              />
              {nameErr != undefined && (
                <div id="provider-name-error" data-testid="provider-name-error" style={{ fontSize: 12, color: 'var(--needs-input)', marginTop: 4 }}>
                  {nameErr}
                </div>
              )}
            </Row>

            {reconfiguring && (
              <div data-testid="provider-reconfigure-warning" style={{ fontSize: 12, color: 'var(--needs-input)' }}>
                You're updating “{form.name}” ({flags ? typeLabelOf(flags) : ''}). To add another
                {' '}{flags ? typeLabelOf(flags) : ''} instance instead, change the name.
              </div>
            )}

            {formFields()}
            {formActions()}
          </div>
        )}

        {mode === 'edit' && selected && (
          <div
            className="flex flex-col gap-4"
            style={{ maxWidth: 640, margin: '0 auto' }}
            data-testid={`provider-form-${selected.name}`}
          >
            <div className="flex items-center gap-2">
              <span className="text-lg font-semibold" style={{ color: 'var(--text-primary)' }}>
                {instanceLabel(selected)}
              </span>
              {defaultProvider === selected.name && (
                <span className="pill" style={{ background: 'var(--bg-elevated)', color: 'var(--text-faint)', fontSize: 11, padding: '0 6px' }}>
                  default
                </span>
              )}
              {!selected.problem && (
                <span className="pill" style={{ background: 'var(--bg-elevated)', color: authBadgeColor(selected.authStatus), fontSize: 11, padding: '0 6px' }}>
                  {AUTH_STATUS_LABELS[selected.authStatus]}
                </span>
              )}
            </div>

            {selected.problem ? (
              <div className="flex flex-col gap-3" data-testid="provider-problem">
                <div style={{ fontSize: 13, color: 'var(--needs-input)' }}>
                  {selected.problem} — fix or delete it here, or edit config.toml.
                </div>
                {deleteSection()}
              </div>
            ) : (
              <>
                <Row label="Unique Name" htmlFor="provider-name-ro" hint="A provider's name can't be changed — delete and re-create to rename.">
                  <input id="provider-name-ro" data-testid="provider-name-readonly" type="text" value={selected.name} readOnly style={{ ...inputStyle, opacity: 0.7 }} />
                </Row>
                <Row label="Type" htmlFor="provider-type-ro" hint="A provider's type can't change — delete and re-create to change it.">
                  <input id="provider-type-ro" data-testid="provider-type-readonly" type="text" value={typeLabelOf(selected)} readOnly style={{ ...inputStyle, opacity: 0.7 }} />
                </Row>
                {formFields()}
                {formActions()}
                {deleteSection()}
              </>
            )}
          </div>
        )}
      </div>
    </div>
  )

  // ── Shared form fragments (closure over the state above) ─────────────
  function formFields() {
    return (
      <>
        <Row
          label="API key"
          htmlFor="provider-api-key"
          hint={mode === 'create'
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
            value={form.api_key}
            onChange={(e) => setForm((f) => ({ ...f, api_key: e.target.value }))}
            style={inputStyle}
            placeholder={keyOptional ? '(optional — keyless endpoint)' : 'Enter API key'}
            autoComplete="off"
            disabled={isVaultLocked}
            aria-invalid={formErrorField === 'api_key'}
            data-testid="provider-api-key-input"
          />
          {formErrorField === 'api_key' && formError && (
            <div style={{ fontSize: 12, color: 'var(--needs-input)', marginTop: 4 }}>{formError}</div>
          )}
        </Row>

        <Row
          label={baseUrlRequired ? 'Base URL *' : 'Base URL'}
          htmlFor="provider-base-url"
          hint={baseUrlRequired
            ? 'Required — the full URL including the API path, e.g. https://host/v1.'
            : flags?.defaultBaseUrl
              ? `Fixed default: ${flags.defaultBaseUrl}`
              : 'Custom API endpoint URL (optional).'}
        >
          <input
            id="provider-base-url"
            type="text"
            value={baseUrlEditable ? form.base_url : fixedBaseValue}
            onChange={(e) => setForm((f) => ({ ...f, base_url: e.target.value }))}
            style={baseUrlEditable ? inputStyle : { ...inputStyle, opacity: 0.7 }}
            placeholder={flags?.defaultBaseUrl ?? (baseUrlRequired ? 'https://host/v1' : '(optional)')}
            autoComplete="off"
            readOnly={!baseUrlEditable}
            aria-required={baseUrlRequired}
            aria-invalid={formErrorField === 'base_url'}
            data-testid="provider-base-url-input"
          />
          {formErrorField === 'base_url' && formError && (
            <div style={{ fontSize: 12, color: 'var(--needs-input)', marginTop: 4 }}>{formError}</div>
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
            value={form.default_model}
            onChange={(e) => setForm((f) => ({ ...f, default_model: e.target.value }))}
            style={inputStyle}
            placeholder={defaultModelRequired ? 'e.g. qwen2.5-7b-instruct' : 'e.g. claude-sonnet-4-20250514'}
            autoComplete="off"
            aria-required={defaultModelRequired}
            aria-invalid={formErrorField === 'default_model'}
            data-testid="provider-default-model-input"
          />
          {formErrorField === 'default_model' && formError && (
            <div style={{ fontSize: 12, color: 'var(--needs-input)', marginTop: 4 }}>{formError}</div>
          )}
        </Row>

        {formError && !formErrorField && (
          <div data-testid="provider-form-error" style={{ fontSize: 12, color: 'var(--needs-input)' }}>
            {formError}
          </div>
        )}
      </>
    )
  }

  function formActions() {
    return (
      <div className="flex gap-2" style={{ borderTop: '1px solid var(--border)', paddingTop: 16 }}>
        <button
          type="button"
          className="btn btn-primary px-3 py-2 rounded-lg text-sm font-medium"
          onClick={handleSubmit}
          disabled={!canSubmit}
          aria-label={submitLabel}
          data-testid="provider-save"
        >
          {submitLabel}
        </button>
        <button type="button" className="btn btn-ghost px-3 py-2 rounded-lg text-sm font-medium" onClick={handleCancel}>
          Cancel
        </button>
        {mode === 'edit' && selected && confirmingDelete !== selected.name && (
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
              if (ok) { await refreshDefault(); refresh() }
              else setFormError('Could not change the default — the backend may be unreachable.')
            }}
            data-testid={defaultProvider === selected.name ? 'clear-default-provider' : 'set-default-provider'}
          >
            {defaultProvider === selected.name ? 'Clear default' : 'Set as default'}
          </button>
        )}
      </div>
    )
  }

  function deleteSection() {
    if (!selected) return null
    const isDefault = defaultProvider === selected.name
    return (
      <div className="flex flex-col gap-2" style={{ borderTop: '1px solid var(--border)', paddingTop: 16 }}>
        {confirmingDelete !== selected.name ? (
          <button
            type="button"
            className="btn btn-danger-ghost px-3 py-2 rounded-lg text-sm font-medium"
            onClick={() => setConfirmingDelete(selected.name)}
            aria-label="Delete provider"
            data-testid="provider-delete"
          >
            Delete
          </button>
        ) : (
          <div className="flex flex-col gap-2" data-testid="provider-delete-confirm">
            <span className="text-sm" style={{ color: 'var(--needs-input)' }}>
              {deleteConfirmText(selected, isDefault)}
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
              <button type="button" className="btn btn-ghost px-3 py-2 rounded-lg text-sm font-medium" onClick={() => setConfirmingDelete(null)}>
                Cancel
              </button>
            </div>
          </div>
        )}
      </div>
    )
  }
}
