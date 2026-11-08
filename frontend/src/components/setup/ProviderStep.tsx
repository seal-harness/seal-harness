import { useMemo, useState } from 'react'
import { testProvider, type SetupResult } from '../../hooks/useSetup'
import { providerLabel } from '../../lib/providerLabels'
import type { ProviderCard, SetupStep } from '../../lib/setupSteps'

type SaveState = { status: 'idle' } | { status: 'saving' } | { status: 'saved' } | { status: 'failed'; result: SetupResult }

/**
 * The provider step.
 *
 * It renders entirely from `state.providers`, which the gateway already
 * carries on `GET /api/setup`: calling `/api/providers/all` here would decrypt
 * the vault once per provider name on every render (and, for a YubiKey vault,
 * ask for a touch). Test-connection is a separate, explicit action — the one
 * place a touch is allowed to happen.
 *
 * First run writes with a single `POST /api/providers`; the default-provider
 * `PUT` is deliberately not issued, because the wizard has exactly one
 * provider to offer at that point. If the operator already had a provider but
 * no default, the server's step detail says so ("Choose which provider new
 * sessions should use") and that message is rendered here verbatim.
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
  const [selected, setSelected] = useState<string>(
    defaultCard?.id ?? providers.find((p) => p.configured)?.id ?? providers[0]?.id ?? '',
  )
  const [apiKey, setApiKey] = useState('')
  const [dirty, setDirty] = useState(false)
  const [save, setSave] = useState<SaveState>({ status: 'idle' })
  const [ping, setPing] = useState<SetupResult | null>(null)
  const [pinging, setPinging] = useState(false)

  const firstProvider = providers[0]
  if (firstProvider === undefined) {
    return (
      <p className="mt-4 text-sm text-slate-400">
        No providers are available in this build. Check the gateway version.
      </p>
    )
  }

  // The selection can arrive before the list does (the step renders while the
  // state is still loading in some flows). Fall back to the first usable card
  // rather than leaving the form with no provider selected.
  const fallback = defaultCard ?? providers.find((p) => p.configured) ?? firstProvider
  const effectiveId = providers.some((p) => p.id === selected) ? selected : fallback.id
  const card = providers.find((p) => p.id === effectiveId)

  const saveKey = async (): Promise<void> => {
    setSave({ status: 'saving' })
    const res = await fetch('/api/providers', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ name: effectiveId, api_key: apiKey }),
    })
    if (res.ok) {
      // The field is cleared: the key is now in the vault, and keeping it in
      // component state would be the only place it outlives the request.
      setApiKey('')
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

  const runPing = async (): Promise<void> => {
    setPinging(true)
    const res = await testProvider(effectiveId, card?.default_model ?? undefined)
    setPinging(false)
    setPing(res)
  }

  const pingOk = ping !== null && ping.ok
  const pingBody = (ping?.body ?? null) as { ok?: boolean; error?: string; detail?: string } | null

  return (
    <div className="mt-4 space-y-4 text-sm text-slate-300">
      <ul className="space-y-2" aria-label="Providers">
        {providers.map((provider) => (
          <li key={provider.id}>
            <label className="flex items-center gap-2">
              <input
                type="radio"
                name="provider"
                value={provider.id}
                checked={provider.id === effectiveId}
                onChange={() => { setSelected(provider.id); setDirty(true); setPing(null) }}
              />
              <span>{providerLabel(provider.id)}</span>
              {provider.isDefault ? <span className="text-xs text-emerald-400">default</span> : null}
              {provider.configured ? (
                <span className="text-xs text-slate-400">configured</span>
              ) : (
                <span className="text-xs text-slate-500">no credential</span>
              )}
              {provider.default_model !== null ? (
                <span className="text-xs text-slate-500">{provider.default_model}</span>
              ) : null}
            </label>
          </li>
        ))}
      </ul>

      {card !== undefined && !card.configured ? (
        <label className="block">
          <span className="block">API key for {providerLabel(card.id)}</span>
          <input
            type="password"
            value={apiKey}
            onChange={(e) => { setApiKey(e.target.value); setDirty(true) }}
            className="mt-1 w-full rounded border border-slate-700 bg-slate-900 px-2 py-1 text-slate-100"
          />
        </label>
      ) : null}

      <div className="flex gap-2">
        <button
          type="button"
          disabled={save.status === 'saving' || !dirty}
          onClick={() => { void saveKey() }}
          className="rounded bg-emerald-700 px-3 py-2 text-white disabled:opacity-50"
        >
          Save
        </button>
        {/* Test is only meaningful against stored config: while the field is
            dirty the value on the server is not the value on screen. */}
        <button
          type="button"
          disabled={dirty || pinging}
          onClick={() => { void runPing() }}
          className="rounded bg-slate-700 px-3 py-2 text-slate-100 disabled:opacity-50"
        >
          Test connection
        </button>
      </div>

      {save.status === 'failed' ? (
        <p role="alert" className="text-red-300">
          {save.result.error}
          {save.result.hint !== null ? ` ${save.result.hint}` : ''}
        </p>
      ) : null}

      {ping !== null ? (
        <p role="status" aria-live="polite" className={pingOk && pingBody?.ok !== false ? 'text-emerald-300' : 'text-amber-300'}>
          {pingBody?.ok === false
            ? `Connection failed: ${pingBody.error ?? 'unknown error'}`
            : 'Credentials resolved.'}
        </p>
      ) : null}

      {step.detail !== null && step.status !== 'ready' ? (
        <p className="text-xs text-slate-400">{step.detail}</p>
      ) : null}
    </div>
  )
}
