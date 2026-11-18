import { useEffect, useMemo, useState } from 'react'
import { setDefaultProvider, testProvider, type SetupResult } from '../../hooks/useSetup'
import { providerLabel } from '../../lib/providerLabels'
import { readinessHint } from '../../lib/readiness'
import type { ProviderCard, SetupStep } from '../../lib/setupSteps'
import type { ProviderReadiness } from '../../types'
import * as s from './styles'
import {
  ProviderFormFields,
  emptyProviderFormValues,
  modelsFromText,
  type ProviderFormValues,
} from '../ProviderFormFields'

type SaveState =
  | { status: 'idle' }
  | { status: 'saving' }
  | { status: 'saved' }
  | { status: 'failed'; result: SetupResult }

/**
 * The provider step.
 *
 * It renders entirely from `state.providers`, which the gateway already
 * carries on `GET /api/setup`: calling `/api/providers/all` here would decrypt
 * the vault once per provider name on every render (and, for a YubiKey vault,
 * ask for a touch). Test-connection is a separate, explicit action — the one
 * place a touch is allowed to happen.
 *
 * There are two ways to finish this step, and which one is offered depends on
 * the server's own state:
 *
 * - the selected provider has **no credential** → collect one and `POST
 *   /api/providers` (which also makes it the default when none is set);
 * - the selected provider is **already configured** (a keyless local Ollama
 *   is configured by definition, so this is the common first run) → there is
 *   nothing to save; the only thing missing is the choice, so offer `PUT
 *   /api/providers/default`. Without this the step offered a disabled Save
 *   button and no way forward — no amount of typing would enable it.
 */
/**
 * Does this readiness state mean "cannot be used right now"?
 *
 * Deliberately narrow. Only the three states that positively mean *the thing is
 * absent* block selection:
 *
 * - `pending` — nothing has been observed yet. Blocking here would disable the
 *   button on first paint for every provider, before any probe finished.
 * - `unknown` — the probe ran and failed unexplainably. We do not know, so we
 *   do not block (and we certainly do not claim).
 * - `cloud` — an `ollama.com` endpoint is not probed; it is not a local
 *   absence.
 * - `no-fitting-model` — advisory only (design D5.4). Turning it into a
 *   verdict is exactly the error the design forbids.
 * - `ready`, and absent readiness (a non-Ollama card) — usable.
 */
function readinessBlocksSelection(readiness: ProviderReadiness | undefined): boolean {
  return readiness === 'not-installed' || readiness === 'not-running' || readiness === 'no-models'
}

/** Every built-in type id is reserved as an instance name (D9). Keeping it in
 *  one list means adding a provider type cannot leave a stale copy behind. */
const RESERVED_INSTANCE_NAMES = [
  'all', 'default',
  'anthropic', 'ollama', 'ollama-cloud', 'openrouter', 'openai', 'openai-compatible',
]

export function ProviderStep({
  step,
  providers,
  onDone,
}: {
  step: SetupStep
  providers: ProviderCard[]
  onDone: () => void
}) {
  const defaultCard = useMemo(() => providers.find((p) => p.isDefault), [providers])
  const firstProvider = providers[0]
  const [selected, setSelected] = useState<string>(
    defaultCard?.id ?? providers.find((p) => p.configured)?.id ?? firstProvider?.id ?? '',
  )
  // API key, endpoint, default model, and frequent-model list. Shared with
  // the Providers tab's form so both write the same config.
  const [form, setForm] = useState<ProviderFormValues>(emptyProviderFormValues())
  // The unique instance name for an OpenAI-compatible provider. This becomes
  // the provider id in config/vault and the label shown in the Providers list.
  const [instanceName, setInstanceName] = useState('')
  const [dirty, setDirty] = useState(false)
  const [save, setSave] = useState<SaveState>({ status: 'idle' })
  const [ping, setPing] = useState<SetupResult | null>(null)
  const [pinging, setPinging] = useState(false)
  // Confirm-before-skip: the escape hatch asks once rather than silently
  // letting the operator through to a product that cannot answer.
  const [finishingAnyway, setFinishingAnyway] = useState(false)

  const fallback = defaultCard ?? providers.find((p) => p.configured) ?? firstProvider
  const effectiveId = providers.some((p) => p.id === selected) ? selected : (fallback?.id ?? '')
  const card = providers.find((p) => p.id === effectiveId)

  // The selected provider cannot be used right now. Only meaningful for a card
  // the wizard would otherwise let through via `Use <provider>` — i.e. one the
  // server already counts as configured.
  const blocked = card !== undefined
    && card.configured
    && !card.isDefault
    && readinessBlocksSelection(card.readiness)
  const blockedReason =
    card !== undefined && card.readiness !== undefined && readinessBlocksSelection(card.readiness)
      ? readinessHint(card.readiness, card.default_model ?? undefined)
      : null

  // Seed the shared fields from the selected card. In particular, an existing
  // frequent-model list must be shown (and round-tripped) instead of being
  // silently cleared by an empty textarea on save.
  useEffect(() => {
    if (card === undefined) return
    setForm({
      apiKey: '',
      baseUrl: '',
      defaultModel: card.default_model ?? '',
      modelsText: (card.models ?? []).join('\n'),
    })
    setDirty(false)
    setSave({ status: 'idle' })
    setPing(null)
  }, [card?.id])

  if (firstProvider === undefined) {
    return (
      <p style={{ ...s.mutedStyle, marginTop: 16 }}>
        No providers are available in this build. Check the gateway version.
      </p>
    )
  }

  const needsBaseUrl = card?.requires_base_url === true
  const needsName = card?.requires_name === true
  // D7: `requires_base_url` means REQUIRED, not VISIBLE. Ollama's base URL is
  // optional yet essential - it is the only GUI path to a remote daemon - so
  // visibility gets its own predicate. `openai` and `ollama-cloud` carry a
  // built-in endpoint, so the wizard never asks for one.
  const isHiddenBaseUrl = effectiveId === 'openai' || effectiveId === 'ollama-cloud'
  const showBaseUrl = !isHiddenBaseUrl
  const baseUrlOk = !needsBaseUrl || /^https?:\/\/\S+$/.test(form.baseUrl.trim())
  const nameOk = !needsName || (
    /^[a-z0-9](?:[a-z0-9-]{0,30}[a-z0-9])?$/.test(instanceName.trim())
    && !instanceName.includes('--')
    && !RESERVED_INSTANCE_NAMES.includes(instanceName.trim())
  )
  const canSaveKey = dirty && baseUrlOk && nameOk
  const saveDisabled = save.status === 'saving' || !canSaveKey

  const saveKey = async (): Promise<void> => {
    setSave({ status: 'saving' })
    const res = await fetch('/api/providers', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        name: needsName ? instanceName.trim() : effectiveId,
        ...(needsName ? { type: 'openai-compatible' } : {}),
        api_key: form.apiKey,
        // Gated on VISIBILITY, not on needsBaseUrl: that flag is false for
        // Ollama, so keying the payload on it would silently drop a typed
        // remote-daemon URL (D7).
        ...(showBaseUrl && form.baseUrl.trim() ? { base_url: form.baseUrl.trim() } : {}),
        ...(form.defaultModel.trim() ? { default_model: form.defaultModel.trim() } : {}),
        models: modelsFromText(form.modelsText),
      }),
    })
    if (res.ok) {
      // The field is cleared: the key is now in the vault, and keeping it in
      // component state would be the only place it outlives the request.
      setForm(emptyProviderFormValues())
      setInstanceName('')
      setDirty(false)
      setSave({ status: 'saved' })
      onDone()
      return
    }
    let body: unknown = null
    try {
      body = await res.json()
    } catch {
      body = null
    }
    const record = (typeof body === 'object' && body !== null ? body : {}) as Record<string, unknown>
    setSave({
      status: 'failed',
      result: {
        status: res.status,
        ok: false,
        error: typeof record.error === 'string' ? record.error : `save failed (${res.status})`,
        hint: typeof record.hint === 'string' ? record.hint : null,
        body,
      },
    })
  }

  const useAsDefault = async (): Promise<void> => {
    setSave({ status: 'saving' })
    const res = await setDefaultProvider(effectiveId)
    setSave(res.ok ? { status: 'saved' } : { status: 'failed', result: res })
    if (res.ok) onDone()
  }

  const runPing = async (): Promise<void> => {
    setPinging(true)
    const res = await testProvider(effectiveId, card?.default_model ?? undefined)
    setPinging(false)
    setPing(res)
  }

  const pingBody = (ping?.body ?? null) as { ok?: boolean; error?: string; detail?: string } | null
  const pingFailed = pingBody?.ok === false

  return (
    <div style={{ marginTop: 16 }}>
      <ul aria-label="Providers" style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
        {providers.map((provider) => (
          <li key={provider.id}>
            <label
              style={{
                ...s.choiceStyle(provider.id === effectiveId),
                display: 'flex',
                alignItems: 'center',
                gap: 10,
              }}
            >
              <input
                type="radio"
                name="provider"
                value={provider.id}
                checked={provider.id === effectiveId}
                onChange={() => { setSelected(provider.id); setDirty(true); setPing(null) }}
              />
              <span style={{ fontSize: 14, color: 'var(--text-primary)' }}>
                {providerLabel(provider.id)}
              </span>
              {provider.isDefault ? <span className="pill" style={{ color: 'var(--success)' }}>default</span> : null}
              {provider.default_model !== null ? (
                <span style={{ fontSize: 12, color: 'var(--text-faint)' }}>{provider.default_model}</span>
              ) : null}
            </label>
          </li>
        ))}
      </ul>

      {card !== undefined && needsName ? (
        <label style={{ ...s.labelStyle, marginTop: 14 }}>
          Unique name
          <input
            type="text"
            placeholder="e.g. local-vllm"
            value={instanceName}
            onChange={(e) => { setInstanceName(e.target.value); setDirty(true) }}
            style={s.inputStyle}
            aria-invalid={!nameOk}
          />
          <span style={{ ...s.faintStyle, display: 'block', marginTop: 4 }}>
            {nameOk
              ? '1–32 characters: a–z, 0–9 and “-”. This id identifies the provider in the Providers list.'
              : 'Use 1–32 characters: a–z, 0–9 and “-” (no leading/trailing “-”, no “--”).'}
          </span>
        </label>
      ) : null}
      {card !== undefined && !card.configured && (
        <ProviderFormFields
          idPrefix="setup-provider"
          values={form}
          onChange={(patch) => { setForm((f) => ({ ...f, ...patch })); setDirty(true) }}
          layout="stacked"
          creating
          showBaseUrl={showBaseUrl}
          baseUrlError={needsBaseUrl && !baseUrlOk ? 'Enter an http:// or https:// URL.' : null}
        />
      )}

      <div style={{ display: 'flex', gap: 8, marginTop: 16 }}>
        {card !== undefined && card.configured ? (
          <button
            type="button"
            disabled={save.status === 'saving' || card.isDefault || blocked}
            onClick={() => { void useAsDefault() }}
            className={s.primaryButtonClass}
          >
            {card.isDefault
              ? `${providerLabel(card.id)} is the default`
              : `Use ${providerLabel(card.id)}`}
          </button>
        ) : (
          <button
            type="button"
            disabled={saveDisabled}
            onClick={() => { void saveKey() }}
            className={s.primaryButtonClass}
          >
            Save
          </button>
        )}
        {/* Test is only meaningful against stored config: while the field is
            dirty the value on the server is not the value on screen. */}
        <button
          type="button"
          disabled={dirty || pinging}
          onClick={() => { void runPing() }}
          className={s.ghostButtonClass}
        >
          Test connection
        </button>
      </div>

      {/* Why the CTA above is disabled, and how to get unstuck.
          The escape hatch is not decoration: Ollama's `configured` is true from
          config alone (Registry.hs), so on a machine that has never installed
          it `required_complete` is already true and the wizard is the ONLY
          screen the operator sees. A disabled button with no way forward would
          hard-block them out of the product. `onDone` refreshes the setup
          state, and the gate then renders the app. */}
      {blocked ? (
        <div style={{ marginTop: 12 }} data-testid="setup-provider-blocked">
          <p role="alert" style={{ ...s.warningStyle }}>
            {blockedReason ?? `${providerLabel(card?.id ?? '')} is not ready.`}
          </p>
          {/* The secondary finish path. Kept separate from the primary CTA so
              the explanation stays adjacent to the disabled button. */}
          {!finishingAnyway ? (
            <button
              type="button"
              onClick={() => setFinishingAnyway(true)}
              className={s.ghostButtonClass}
              style={{ marginTop: 8 }}
              data-testid="setup-provider-skip"
            >
              Continue without a working provider
            </button>
          ) : (
            <div style={{ marginTop: 8 }}>
              <p style={{ ...s.mutedStyle }}>
                Finish setup now? Messages will fail until{' '}
                {providerLabel(card?.id ?? '')} is available.
              </p>
              <button
                type="button"
                onClick={onDone}
                className={s.ghostButtonClass}
                data-testid="setup-provider-skip-confirm"
              >
                Finish setup
              </button>
            </div>
          )}
        </div>
      ) : null}

      {save.status === 'failed' ? (
        <p role="alert" style={{ ...s.errorStyle, marginTop: 12 }}>
          {save.result.error}
          {save.result.hint !== null ? ` ${save.result.hint}` : ''}
        </p>
      ) : null}

      {ping !== null ? (
        <p
          role="status"
          aria-live="polite"
          style={{ ...(pingFailed ? s.warningStyle : s.successStyle), marginTop: 12 }}
        >
          {pingFailed
            ? `Connection failed: ${pingBody?.error ?? 'unknown error'}`
            : (pingBody?.detail ?? 'Credentials resolved.')}
        </p>
      ) : null}

      {step.detail !== null && step.status !== 'ready' ? (
        <p style={{ ...s.faintStyle, marginTop: 12 }}>{step.detail}</p>
      ) : null}
    </div>
  )
}
