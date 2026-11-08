import { useState } from 'react'
import { provisionVault, type SetupResult, type VaultBackend } from '../../hooks/useSetup'
import type { SetupStep } from '../../lib/setupSteps'

type Choice = 'local' | 'yubikey' | 'user'

/**
 * The vault step's cards.
 *
 * Three properties are load-bearing:
 *
 * - the cards only appear for `create` (a recorded key shows `resume`, and a
 *   configured vault shows `reopen`; offering "create" there would be a 409);
 * - no field is ever pre-filled from a previous attempt — a key path is not a
 *   value to remember and echo back;
 * - a 400 is attributed to the field it names, because "invalid request" with
 *   two text inputs is a guessing game.
 */
export function VaultStep({
  step,
  onDone,
}: {
  step: SetupStep
  onDone: () => void
}) {
  const [choice, setChoice] = useState<Choice | null>(null)
  const [touch, setTouch] = useState(true)
  const [pin, setPin] = useState(true)
  const [recipient, setRecipient] = useState('')
  const [identityPath, setIdentityPath] = useState('')
  const [result, setResult] = useState<SetupResult | null>(null)
  const [busy, setBusy] = useState(false)

  const canCreate = step.actions.includes('create')

  const submit = async (spec: VaultBackend): Promise<void> => {
    setBusy(true)
    const res = await provisionVault(spec)
    setBusy(false)
    setResult(res)
    if (res.ok) onDone()
  }

  return (
    <div className="mt-4 space-y-4">
      {canCreate ? (
        <div className="grid gap-3 sm:grid-cols-3" role="group" aria-label="Vault backends">
          {(
            [
              ['local', 'Local age key', 'A key file on this machine.'],
              ['yubikey', 'YubiKey', 'The key stays on the token.'],
              ['user', 'My own key', 'Bring an existing age identity.'],
            ] as const
          ).map(([id, title, blurb]) => (
            <button
              key={id}
              type="button"
              aria-pressed={choice === id}
              onClick={() => { setChoice(id); setResult(null) }}
              className={`rounded border p-3 text-left text-sm ${
                choice === id ? 'border-emerald-500 text-slate-100' : 'border-slate-700 text-slate-300'
              }`}
            >
              <span className="block font-medium">{title}</span>
              <span className="block text-xs text-slate-400">{blurb}</span>
            </button>
          ))}
        </div>
      ) : null}

      {choice === 'local' ? (
        <button
          type="button"
          disabled={busy}
          onClick={() => { void submit({ backend: 'local' }) }}
          className="rounded bg-emerald-700 px-3 py-2 text-sm text-white disabled:opacity-50"
        >
          Create the vault
        </button>
      ) : null}

      {choice === 'yubikey' ? (
        <div className="space-y-3 text-sm text-slate-300">
          <label className="flex items-center gap-2">
            <input type="checkbox" checked={touch} onChange={(e) => setTouch(e.target.checked)} />
            Require a touch to decrypt
          </label>
          <label className="flex items-center gap-2">
            <input type="checkbox" checked={pin} onChange={(e) => setPin(e.target.checked)} />
            Require the PIN once per session
          </label>
          <button
            type="button"
            disabled={busy}
            onClick={() => { void submit({ backend: 'yubikey', touch, pin }) }}
            className="rounded bg-emerald-700 px-3 py-2 text-sm text-white disabled:opacity-50"
          >
            Generate on the token
          </button>
          <p className="text-xs text-slate-400" aria-live="polite">
            A token cannot answer a browser prompt: if the plugin needs a terminal,
            you will get the exact command to run and a Re-check button.
          </p>
        </div>
      ) : null}

      {choice === 'user' ? (
        <form
          className="space-y-3"
          onSubmit={(e) => {
            e.preventDefault()
            void submit({ backend: 'user', recipient, identity_path: identityPath })
          }}
        >
          <Field
            label="Recipient (age1…)"
            value={recipient}
            onChange={setRecipient}
            error={fieldError(result, 'recipient')}
          />
          <Field
            label="Identity file path"
            value={identityPath}
            onChange={setIdentityPath}
            error={fieldError(result, 'identity_path')}
          />
          <button
            type="submit"
            disabled={busy}
            className="rounded bg-emerald-700 px-3 py-2 text-sm text-white disabled:opacity-50"
          >
            Use my key
          </button>
        </form>
      ) : null}

      {result !== null && !result.ok ? <VaultFailure result={result} /> : null}
    </div>
  )
}

function fieldError(result: SetupResult | null, field: string): string | null {
  if (result === null || result.ok) return null
  const message = `${result.error ?? ''} ${result.hint ?? ''}`.toLowerCase()
  if (!message.includes(field)) return null
  return result.error ?? 'invalid value'
}

function VaultFailure({ result }: { result: SetupResult }) {
  if (result.status === 400) {
    return (
      <p role="alert" className="text-sm text-red-300">
        {result.error ?? 'The request was rejected.'}
        {result.hint !== null ? ` ${result.hint}` : ''}
      </p>
    )
  }
  if (result.status === 409) {
    return (
      <p role="alert" className="text-sm text-amber-300">
        {result.error ?? 'A vault key is already recorded.'}
        {result.hint !== null ? ` ${result.hint}` : ''}
      </p>
    )
  }
  if (result.status === 422) {
    return (
      <div role="alert" className="space-y-2 text-sm text-amber-200">
        <p>{result.error ?? 'This machine cannot complete the step.'}</p>
        {result.hint !== null ? (
          <pre className="overflow-x-auto rounded bg-slate-900 p-2 text-xs">{result.hint}</pre>
        ) : null}
        <p className="text-xs text-slate-400">
          Run that command in a terminal, then press Re-check.
        </p>
      </div>
    )
  }
  return (
    <p role="alert" className="text-sm text-red-300">
      Unexpected response ({result.status}). This looks like a bug — please report it with the code above.
    </p>
  )
}

function Field({
  label,
  value,
  onChange,
  error,
}: {
  label: string
  value: string
  onChange: (next: string) => void
  error: string | null
}) {
  return (
    <label className="block text-sm text-slate-300">
      <span className="block">{label}</span>
      <input
        type="text"
        value={value}
        onChange={(e) => onChange(e.target.value)}
        className="mt-1 w-full rounded border border-slate-700 bg-slate-900 px-2 py-1 text-slate-100"
      />
      {error !== null ? (
        <span role="alert" className="mt-1 block text-xs text-red-300">{error}</span>
      ) : null}
    </label>
  )
}
