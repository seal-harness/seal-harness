import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import type { ProviderInput, ProviderAuthStatus, ProviderReadiness } from '../types'
import { readinessLabel, readinessTone, type ReadinessTone } from '../lib/readiness'
import {
  ProviderFormFields,
  emptyProviderFormValues,
  modelsFromText,
  providerFormValuesFrom,
  type ProviderFormValues,
} from './ProviderFormFields'
import {
  createProvider,
  deleteProvider,
  fetchDefaultProvider,
  notifyProvidersChanged,
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

/**
 * One rendered badge. `readiness` badges are Ollama's observed state; `auth`
 * badges are the pre-existing credential label.
 */
interface ProviderBadge {
  kind: 'readiness' | 'auth'
  text: string
  color: string
}

/**
 * The D3.2 override table, as one pure function so both render sites (the list
 * row and the editor pill) cannot drift.
 *
 * The order of the clauses is load-bearing:
 *
 * 1. `pending` is checked **first** and contributes no readiness badge, so the
 *    "both badges" branches can never promise a badge the label table says is
 *    blank. (A `pending` + `vault-locked` Ollama is reachable: an `ollama.com`
 *    base URL with a locked vault.)
 * 2. The credential clause requires readiness to be **present**. Without that
 *    guard it would fire for anthropic/openrouter/openai rows that have no
 *    readiness at all, drawing a blank second badge on the most common
 *    credential-problem case (vault-locked Anthropic).
 * 3. `cloud` keeps both badges: it is not a local verdict, so the credential
 *    badge still carries information.
 * 4. Any other present, specific readiness **replaces** the credential badge —
 *    "Not Running" is strictly more useful than "Keyless".
 * 5. Absent readiness falls back to exactly today's behaviour.
 */
export function providerBadges(
  authStatus: ProviderAuthStatus,
  readiness: ProviderReadiness | undefined,
  usableModels?: number,
): ProviderBadge[] {
  const auth: ProviderBadge = {
    kind: 'auth',
    text: AUTH_STATUS_LABELS[authStatus],
    color: authBadgeColor(authStatus),
  }
  if (readiness === undefined) return [auth]
  if (readiness === 'pending') return [auth]
  const rd: ProviderBadge = {
    kind: 'readiness',
    text: readinessLabel(readiness, usableModels),
    color: readinessColor(readinessTone(readiness)),
  }
  if (readiness === 'cloud') return [rd, auth]
  if (authStatus === 'none' || authStatus === 'vault-locked') return [rd, auth]
  return [rd]
}

/** Map a readiness tone onto the app's existing colour variables. */
function readinessColor(tone: ReadinessTone): string {
  switch (tone) {
    case 'ok':
      return 'var(--accent)'
    case 'warn':
      return 'var(--needs-input)'
    case 'muted':
      return 'var(--text-muted)'
    case 'faint':
      return 'var(--text-faint)'
  }
}

const PROVIDER_LABELS: Record<string, string> = {
  anthropic: 'Anthropic',
  ollama: 'Ollama',
  'ollama-cloud': 'Ollama Cloud',
  openrouter: 'OpenRouter',
  openai: 'OpenAI',
  'openai-compatible': 'OpenAI-compatible',
}

/** The generic type's dropdown option text. Longer than the short label
 *  because its id no longer implies "not real OpenAI" (design item 39). */
const OPENAI_COMPATIBLE_OPTION = 'OpenAI-compatible (custom / self-hosted)'

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

/** Provider ids that already mean a built-in type (and are therefore not
 *  available as a *new* custom instance name). `openai` is allowed: it is the
 *  built-in OpenAI-compatible instance, and reconfiguring it keeps the same
 *  name. */
const RESERVED_PROVIDER_NAMES = new Set([
  'all', 'default',
  // Every built-in type id is reserved (D9): a custom instance can no longer
  // be named after one.
  'anthropic', 'ollama', 'ollama-cloud', 'openrouter', 'openai', 'openai-compatible',
])

const PROVIDER_NAME_RE = /^[a-z0-9](?:[a-z0-9-]{0,30}[a-z0-9])?$/

/** Validate the unique name of an OpenAI-compatible instance. Returns the
 *  user-facing reason, or null when it is acceptable. */
function providerNameError(name: string, existingCustomNames: Set<string>): string | null {
  const t = name.trim()
  if (!t) return 'Enter a unique name for this provider.'
  if (t.length > 32) return 'Use at most 32 characters.'
  if (!PROVIDER_NAME_RE.test(t) || t.includes('--')) {
    return 'Use 1–32 characters: a–z, 0–9 and “-” (no leading/trailing “-”, no “--”).'
  }
  if (RESERVED_PROVIDER_NAMES.has(t)) return `“${t}” is a reserved provider name.`
  if (existingCustomNames.has(t)) return `A provider named “${t}” already exists.`
  return null
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
  const [formName, setFormName] = useState('')
  const [form, setForm] = useState<ProviderFormValues>(emptyProviderFormValues())
  const [uniqueName, setUniqueName] = useState('')
  const [submitting, setSubmitting] = useState(false)
  const [formError, setFormError] = useState<string | null>(null)
  const [confirmingDelete, setConfirmingDelete] = useState<string | null>(null)
  const [settingDefault, setSettingDefault] = useState(false)

  // Ref holding the latest `providers` list so the seed effect can read it
  // without re-running on every poll tick.
  const providersRef = useRef(providers)
  providersRef.current = providers

  // When the user picks a provider to edit (or starts creating), seed the form.
  useEffect(() => {
    if (creating) {
      setFormName('')
      setForm(emptyProviderFormValues())
      setUniqueName('')
      setFormError(null)
      return
    }
    if (editing) {
      const p = providersRef.current.find((pr) => pr.name === editing)
      if (p) {
        setFormName(p.name)
        setForm(providerFormValuesFrom(p))
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

  // Names already used by custom OpenAI-compatible instances. The built-in
  // rows are intentionally excluded: they are the same instances the operator
  // may reconfigure by selecting their id ("openai-compatible" for the
  // generic type).
  const existingCustomNames = useMemo(
    () => new Set(providers.filter((p) => PROVIDER_LABELS[p.name] === undefined).map((p) => p.name)),
    [providers],
  )

  // The dropdown's own ProviderDetail row. While `creating` is true, `selected`
  // is null, so per-provider values must come from the list the dropdown was
  // built from - never from `selected`.
  const formRow = useMemo(
    () => providers.find((p) => p.name === formName),
    [providers, formName],
  )

  // D7: `requiresBaseUrl` means REQUIRED, not VISIBLE. Visibility has its own
  // predicate and the two must never be conflated: Ollama's base URL is
  // optional yet essential (the only GUI path to a remote daemon), so driving
  // visibility off `requiresBaseUrl` would delete that affordance.
  //
  // When the row is unresolved, treat the field as hidden for the PAYLOAD (an
  // unloaded list must not re-send a stale value) but keep today's render
  // default. `openai` and `ollama-cloud` have built-in endpoints, so the form
  // never asks for one.
  const isHiddenBaseUrl =
    formRow === undefined
      ? formName === 'openai' || formName === 'ollama-cloud'
      : formRow.name === 'openai' || formRow.name === 'ollama-cloud'
  const showBaseUrl = !isHiddenBaseUrl
  const showUniqueName = formRow === undefined
    ? formName === 'openai-compatible'
    : formRow.requiresName
  const requiresBaseUrl = formRow?.requiresBaseUrl === true

  const uniqueNameError = showUniqueName
    ? providerNameError(uniqueName, existingCustomNames)
    : null
  const baseUrlOk =
    !requiresBaseUrl || /^https?:\/\/\S+$/.test(form.baseUrl.trim())

  const handleSubmit = async () => {
    setSubmitting(true)
    setFormError(null)
    const trimmedName = formName.trim()
    if (creating) {
      const customOpenAI = showUniqueName
      const payload: ProviderInput = {
        name: customOpenAI ? uniqueName.trim() : trimmedName,
        ...(customOpenAI ? { type: 'openai-compatible' } : {}),
        api_key: form.apiKey && form.apiKey.trim().length > 0 ? form.apiKey.trim() : undefined,
        // Gated on VISIBILITY, not on requiresBaseUrl. Keying this on the
        // latter would silently drop a typed remote-Ollama URL, because that
        // flag is false for Ollama (D7).
        base_url: showBaseUrl && form.baseUrl && form.baseUrl.trim().length > 0
          ? form.baseUrl.trim()
          : undefined,
        default_model: form.defaultModel && form.defaultModel.trim().length > 0 ? form.defaultModel.trim() : undefined,
        models: modelsFromText(form.modelsText),
      }
      const res = await createProvider(payload)
      setSubmitting(false)
      if (res.ok) {
        refresh()
        notifyProvidersChanged()
        setCreating(false)
        setEditing(res.provider.name)
      } else {
        setFormError(res.error)
      }
    } else if (editing) {
      const payload: ProviderInput = {
        api_key: form.apiKey && form.apiKey.trim().length > 0 ? form.apiKey.trim() : undefined,
        // Same visibility gate as the create path. `providerFormValuesFrom`
        // pre-fills baseUrl from the stored detail, so without this an edit of
        // an OpenAI provider would re-send a value the operator cannot see -
        // contradicting "hidden entirely" (D7).
        base_url: showBaseUrl && form.baseUrl && form.baseUrl.trim().length > 0
          ? form.baseUrl.trim()
          : undefined,
        default_model: form.defaultModel && form.defaultModel.trim().length > 0 ? form.defaultModel.trim() : undefined,
        models: modelsFromText(form.modelsText),
      }
      const res = await updateProvider(editing, payload)
      setSubmitting(false)
      if (res.ok) {
        refresh()
        notifyProvidersChanged()
        setEditing(res.provider.name)
      } else {
        setFormError(res.error)
      }
    }
  }

  const handleDelete = async (name: string) => {
    const ok = await deleteProvider(name)
    if (ok) {
      if (editing === name) setEditing(null)
      if (confirmingDelete === name) setConfirmingDelete(null)
      refresh()
      notifyProvidersChanged()
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

  const isVaultLocked = selected?.authStatus === 'vault-locked'
  const isKeyless = selected?.authStatus === 'keyless'
  const isOllama = selected?.name === 'ollama' || (creating && formName === 'ollama')

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
                    {PROVIDER_LABELS[p.name] ?? p.name}
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
                {/* The badges STACK (a column), they do not sit inline. The
                    row is `text-xs truncate`, so two inline badges would clip
                    the second one out of view entirely. */}
                <div
                  className="flex flex-col mt-0.5"
                  data-testid={`provider-badges-${p.name}`}
                >
                  {providerBadges(p.authStatus, p.readiness, p.readinessModels).map((badge) => (
                    <div
                      key={badge.kind}
                      className="text-xs truncate"
                      data-testid={`provider-badge-${badge.kind}`}
                      style={{ color: badge.color }}
                    >
                      {badge.text}
                    </div>
                  ))}
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
                {creating ? 'New provider' : (PROVIDER_LABELS[selected?.name ?? ''] ?? selected?.name ?? 'Provider')}
              </span>
              {defaultProvider === selected?.name && (
                <span
                  className="pill"
                  style={{ background: 'var(--bg-elevated)', color: 'var(--text-faint)', fontSize: 11, padding: '0 6px' }}
                >
                  default
                </span>
              )}
              {selected && providerBadges(selected.authStatus, selected.readiness, selected.readinessModels).map((badge) => (
                <span
                  key={badge.kind}
                  className="pill"
                  data-testid={`editor-badge-${badge.kind}`}
                  style={{
                    background: 'var(--bg-elevated)',
                    color: badge.color,
                    fontSize: 11,
                    padding: '0 6px',
                  }}
                >
                  {badge.text}
                </span>
              ))}
            </div>

            {creating && (
              <Row label="Provider" htmlFor="provider-name" hint="Select a provider to configure.">
                <select
                  id="provider-name"
                  value={formName}
                  onChange={(e) => {
                    setFormName(e.target.value)
                    setUniqueName('')
                    setForm((f) => ({ ...f, baseUrl: '' }))
                  }}
                  className="composer-select"
                  style={inputStyle}
                >
                  <option value="">(select)</option>
                  {unconfigured.filter((p) => PROVIDER_LABELS[p.name] !== undefined).map((p) => (
                    <option key={p.name} value={p.name}>
                      {p.name === 'openai-compatible'
                        ? OPENAI_COMPATIBLE_OPTION
                        : (PROVIDER_LABELS[p.name] ?? p.name)}
                    </option>
                  ))}
                  {/* Allow already-configured providers too (upsert) */}
                  {configured.filter((p) => PROVIDER_LABELS[p.name] !== undefined).map((p) => (
                    <option key={p.name} value={p.name}>
                      {PROVIDER_LABELS[p.name] ?? p.name} (reconfigure)
                    </option>
                  ))}
                </select>
              </Row>
            )}

            {creating && showUniqueName && (
              <Row
                label="Unique Name"
                htmlFor="provider-instance-name"
                hint="1–32 characters: a–z, 0–9 and “-”. This is the provider's id and is shown in the list."
              >
                <input
                  id="provider-instance-name"
                  type="text"
                  value={uniqueName}
                  onChange={(e) => setUniqueName(e.target.value)}
                  style={inputStyle}
                  placeholder="e.g. local-vllm"
                  autoComplete="off"
                  aria-invalid={uniqueNameError !== null}
                  data-testid="provider-instance-name-input"
                />
                {uniqueNameError !== null && (
                  <div
                    data-testid="provider-instance-name-error"
                    style={{ fontSize: 11, color: 'var(--needs-input)', marginTop: 4 }}
                  >
                    {uniqueNameError}
                  </div>
                )}
              </Row>
            )}

            <ProviderFormFields
              idPrefix="provider"
              values={form}
              onChange={(patch) => setForm((f) => ({ ...f, ...patch }))}
              creating={creating}
              isKeyless={isKeyless}
              isVaultLocked={isVaultLocked}
              isOllama={isOllama}
              isOpenAIType={formName === 'openai-compatible'}
              showBaseUrl={showBaseUrl}
              baseUrlError={requiresBaseUrl && !baseUrlOk ? 'Enter an http:// or https:// URL.' : null}
            />

            {formError && (
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
                  disabled={
                    submitting
                    || (creating && !formName.trim())
                    || (creating && showUniqueName && uniqueNameError !== null)
                    || (requiresBaseUrl && !baseUrlOk)
                  }
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