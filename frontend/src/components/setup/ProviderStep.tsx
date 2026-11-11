import { useMemo, useState } from 'react'
import { setDefaultProvider, testProvider, type SetupResult } from '../../hooks/useSetup'
import { providerLabel } from '../../lib/providerLabels'
import type { ProviderCard, SetupStep } from '../../lib/setupSteps'
import * as s from './styles'

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
  const [apiKey, setApiKey] = useState('')
  // Only used by providers with no built-in endpoint (the generic
  // OpenAI-compatible option). Never pre-filled: the endpoint belongs to the
  // operator, and echoing a guess back would be worse than an empty field.
  const [baseUrl, setBaseUrl] = useState('')
  // The unique instance name for an OpenAI-compatible provider. This becomes
  // the provider id in config/vault and the label shown in the Providers list.
  const [instanceName, setInstanceName] = useState('')
  const [dirty, setDirty] = useState(false)
  const [save, setSave] = useState<SaveState>({ status: 'idle' })
  const [ping, setPing] = useState<SetupResult | null>(null)
  const [pinging, setPinging] = useState(false)

  if (firstProvider === undefined) {
    return (
      <p style={{ ...s.mutedStyle, marginTop: 16 }}>
        No providers are available in this build. Check the gateway version.
      </p>
    )
  }

  const fallback = defaultCard ?? providers.find((p) => p.configured) ?? firstProvider
  const effectiveId = providers.some((p) => p.id === selected) ? selected : fallback.id
  const card = providers.find((p) => p.id === effectiveId)
  const needsBaseUrl = card?.requires_base_url === true
  const needsName = card?.requires_name === true
  const baseUrlOk = !needsBaseUrl || /^https?:\/\/\S+$/.test(baseUrl.trim())
  const nameOk = !needsName || (
    /^[a-z0-9](?:[a-z0-9-]{0,30}[a-z0-9])?$/.test(instanceName.trim())
    && !instanceName.includes('--')
    && !['all', 'default', 'anthropic', 'ollama', 'openrouter'].includes(instanceName.trim())
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
        ...(needsName ? { type: 'openai' } : {}),
        api_key: apiKey,
        ...(needsBaseUrl ? { base_url: baseUrl.trim() } : {}),
      }),
    })
    if (res.ok) {
      // The field is cleared: the key is now in the vault, and keeping it in
      // component state would be the only place it outlives the request.
      setApiKey('')
      setBaseUrl('')
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
              <span className="pill" style={{ color: provider.configured ? 'var(--text-muted)' : 'var(--text-faint)' }}>
                {provider.configured ? 'configured' : 'no credential'}
              </span>
              {provider.default_model !== null ? (
                <span style={{ fontSize: 12, color: 'var(--text-faint)' }}>{provider.default_model}</span>
              ) : null}
            </label>
          </li>
        ))}
      </ul>

      {card !== undefined && !card.configured ? (
        <label style={{ ...s.labelStyle, marginTop: 14 }}>
          API key for {providerLabel(card.id)}
          <input
            type="password"
            value={apiKey}
            onChange={(e) => { setApiKey(e.target.value); setDirty(true) }}
            style={s.inputStyle}
          />
        </label>
      ) : null}
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
      {card !== undefined && needsBaseUrl ? (
        <label style={{ ...s.labelStyle, marginTop: 14 }}>
          API endpoint (base URL)
          <input
            type="url"
            placeholder="https://api.openai.com/v1"
            value={baseUrl}
            onChange={(e) => { setBaseUrl(e.target.value); setDirty(true) }}
            style={s.inputStyle}
            aria-invalid={!baseUrlOk}
          />
          <span style={{ ...s.faintStyle, display: 'block', marginTop: 4 }}>
            {baseUrlOk
              ? 'The OpenAI-compatible endpoint, e.g. https://api.openai.com/v1 or http://localhost:8000/v1. Local servers usually accept any non-empty token as the key.'
              : 'Enter an http:// or https:// URL.'}
          </span>
        </label>
      ) : null}

      <div style={{ display: 'flex', gap: 8, marginTop: 16 }}>
        {card !== undefined && card.configured ? (
          <button
            type="button"
            disabled={save.status === 'saving' || card.isDefault}
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
