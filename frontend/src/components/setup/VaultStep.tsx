import { useState } from 'react'
import { provisionVault, type SetupResult, type VaultBackend } from '../../hooks/useSetup'
import type { SetupStep } from '../../lib/setupSteps'
import * as s from './styles'

type Choice = 'local' | 'yubikey' | 'user'

/**
 * The vault step's cards.
 *
 * Three properties are load-bearing:
 *
 * - the cards only appear for `create` (a recorded key shows `resume`, and a
 *   configured vault shows `reopen`; offering "create" there would be a 409),
 *   and `create` has no action-bar button of its own — these cards *are* the
 *   action, and two "Create vault" buttons on one screen is a puzzle, not a
 *   choice;
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
    <div style={{ marginTop: 16 }}>
      {canCreate ? (
        <div
          role="group"
          aria-label="Vault backends"
          style={{ display: 'grid', gridTemplateColumns: 'repeat(3, minmax(0, 1fr))', gap: 10 }}
        >
          {(
            [
              ['local', 'Local key', 'A key file generated on this machine.'],
              ['yubikey', 'YubiKey', 'The key stays on the token.'],
              ['user', 'My own key', 'Bring a key file you already have.'],
            ] as const
          ).map(([id, title, blurb]) => (
            <button
              key={id}
              type="button"
              aria-pressed={choice === id}
              onClick={() => { setChoice(id); setResult(null) }}
              style={s.choiceStyle(choice === id)}
            >
              <span style={s.choiceTitleStyle}>{title}</span>
              <span style={s.choiceBlurbStyle}>{blurb}</span>
            </button>
          ))}
        </div>
      ) : null}

      {choice === 'local' ? (
        <div style={{ marginTop: 16 }}>
          <p style={s.mutedStyle}>
            Seal generates the encryption key on this machine and keeps it in{' '}
            <code style={{ fontFamily: 'var(--font-mono)' }}>~/.seal/keys/</code>.
            Nothing leaves the machine.
          </p>
          <button
            type="button"
            disabled={busy}
            onClick={() => { void submit({ backend: 'local' }) }}
            className={s.primaryButtonClass}
            style={{ marginTop: 12 }}
          >
            Create vault
          </button>
        </div>
      ) : null}

      {choice === 'yubikey' ? (
        <div style={{ marginTop: 16 }}>
          <label style={{ ...s.mutedStyle, display: 'flex', alignItems: 'center', gap: 8 }}>
            <input type="checkbox" checked={touch} onChange={(e) => setTouch(e.target.checked)} />
            Require a touch to decrypt
          </label>
          <label style={{ ...s.mutedStyle, display: 'flex', alignItems: 'center', gap: 8, marginTop: 6 }}>
            <input type="checkbox" checked={pin} onChange={(e) => setPin(e.target.checked)} />
            Require the PIN once per session
          </label>
          <button
            type="button"
            disabled={busy}
            onClick={() => { void submit({ backend: 'yubikey', touch, pin }) }}
            className={s.primaryButtonClass}
            style={{ marginTop: 12 }}
          >
            Generate on the token
          </button>
          <p style={{ ...s.faintStyle, marginTop: 10 }} aria-live="polite">
            A token cannot answer a browser prompt: if the plugin needs a
            terminal, you will get the exact command to run and a Re-check button.
          </p>
        </div>
      ) : null}

      {choice === 'user' ? (
        <form
          style={{ marginTop: 16 }}
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
          <div style={{ marginTop: 10 }}>
            <Field
              label="Identity file path"
              value={identityPath}
              onChange={setIdentityPath}
              error={fieldError(result, 'identity_path')}
            />
          </div>
          <button
            type="submit"
            disabled={busy}
            className={s.primaryButtonClass}
            style={{ marginTop: 14 }}
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
      <p role="alert" style={{ ...s.errorStyle, marginTop: 14 }}>
        {result.error ?? 'The request was rejected.'}
        {result.hint !== null ? ` ${result.hint}` : ''}
      </p>
    )
  }
  if (result.status === 409) {
    return (
      <p role="alert" style={{ ...s.warningStyle, marginTop: 14 }}>
        {result.error ?? 'A vault key is already recorded.'}
        {result.hint !== null ? ` ${result.hint}` : ''}
      </p>
    )
  }
  if (result.status === 422) {
    return (
      <div role="alert" style={{ marginTop: 14 }}>
        <p style={s.warningStyle}>{result.error ?? 'This machine cannot complete the step.'}</p>
        {result.hint !== null ? <pre style={{ ...s.monoStyle, marginTop: 8 }}>{result.hint}</pre> : null}
        <p style={{ ...s.faintStyle, marginTop: 8 }}>
          Run that command in a terminal, then press Re-check.
        </p>
      </div>
    )
  }
  return (
    <p role="alert" style={{ ...s.errorStyle, marginTop: 14 }}>
      Unexpected response ({result.status}). This looks like a bug — please
      report it with the code above.
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
    <label style={s.labelStyle}>
      {label}
      <input
        type="text"
        value={value}
        onChange={(e) => onChange(e.target.value)}
        style={s.inputStyle}
      />
      {error !== null ? (
        <span role="alert" style={{ ...s.errorStyle, display: 'block', marginTop: 4, fontSize: 12 }}>
          {error}
        </span>
      ) : null}
    </label>
  )
}
