import { useEffect, useRef, useState } from 'react'
import { provisionVault, reopenVault } from '../../hooks/useSetup'
import {
  actionLabel,
  barActions,
  firstIncompleteStepIndex,
  resolveRail,
  type ParsedSetupState,
} from '../../lib/setupSteps'
import { ProviderStep } from './ProviderStep'
import { SetupComplete } from './SetupComplete'
import * as s from './styles'
import { VaultStep } from './VaultStep'

/**
 * The wizard shell: a rail on the left, the current step's card on the right,
 * and an action bar built from `step.actions`.
 *
 * The rail and every status come from the server's `SetupState`; this
 * component never guesses readiness. `resolveRail` keeps an unregistered
 * required step visible (a generic card), so a newer server can add a step
 * without this build silently pretending the wizard is done.
 */
export function SetupWizard({
  state,
  refresh,
  onComplete,
}: {
  state: ParsedSetupState
  /** Re-probe `GET /api/setup` (after creating/reopening the vault, saving a
   *  provider, or pressing Re-check). */
  refresh: () => void
  /** Leave the wizard. Called by the completion screen only — the gate uses it
   *  to reveal the app, so completing the steps alone does not do it. */
  onComplete: () => void
}) {
  const rail = resolveRail(state)
  const incomplete = firstIncompleteStepIndex(state)
  const [index, setIndex] = useState(() => incomplete ?? 0)
  const [reopenError, setReopenError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const headingRef = useRef<HTMLHeadingElement | null>(null)
  const firstRender = useRef(true)

  // Auto-advance: when the current step flips to ready, move to the next one
  // that still needs the operator. Blocked steps keep focus (they need an
  // action, not a nudge).
  useEffect(() => {
    if (incomplete === null) return
    const current = rail[index]
    if (current !== undefined && current.step.status === 'ready') {
      setIndex(incomplete)
    }
  }, [state, incomplete, index, rail])

  // Focus the step heading on advance (a11y contract, design §10). Not on the
  // first render: stealing focus from the page on mount is disorienting.
  useEffect(() => {
    if (firstRender.current) {
      firstRender.current = false
      return
    }
    headingRef.current?.focus()
  }, [index])

  if (incomplete === null) {
    return <SetupComplete onComplete={onComplete} />
  }

  const entry = rail[index] ?? rail[0]
  if (entry === undefined) {
    return <SetupComplete onComplete={onComplete} />
  }

  const dispatch = async (verb: string): Promise<void> => {
    if (verb === 'recheck') {
      refresh()
      return
    }
    setBusy(true)
    setReopenError(null)
    const result = verb === 'resume'
      ? await provisionVault({ backend: 'resume' })
      : await reopenVault()
    setBusy(false)
    if (result.ok) {
      refresh()
      return
    }
    // A failed reopen is terminal for this step: the file cannot be opened
    // with the recorded key, and no amount of retrying changes that.
    setReopenError(result.error ?? 'the vault could not be reopened')
  }

  return (
    <div style={{ display: 'flex', gap: 24, alignItems: 'flex-start' }}>
      <nav aria-label="Setup steps" style={s.railStyle}>
        <ol>
          {rail.map((item, i) => (
            <li key={item.id}>
              <button
                type="button"
                aria-current={i === index ? 'step' : undefined}
                onClick={() => setIndex(i)}
                style={s.railItemStyle(i === index)}
              >
                <span style={{ display: 'block', fontSize: 13, fontWeight: 500 }}>
                  {i + 1}. {item.title}
                </span>
                <span style={{ display: 'block', fontSize: 11, color: 'var(--text-faint)', marginTop: 2 }}>
                  {item.step.status}
                </span>
              </button>
            </li>
          ))}
        </ol>
      </nav>

      <section style={{ ...s.cardStyle, flex: 1, minWidth: 0 }}>
        <h2 ref={headingRef} tabIndex={-1} style={s.sectionTitleStyle}>
          {entry.title}
        </h2>
        {entry.step.detail !== null ? (
          <p style={{ ...s.mutedStyle, marginTop: 6 }} aria-live="polite">
            {entry.step.detail}
          </p>
        ) : null}
        {entry.step.status === 'blocked' ? (
          <p role="alert" style={{ ...s.warningStyle, marginTop: 6 }}>
            This step needs attention before you can continue.
          </p>
        ) : null}

        {entry.registered && entry.id === 'vault' ? (
          <VaultStep step={entry.step} onDone={refresh} />
        ) : null}
        {entry.registered && entry.id === 'provider' ? (
          <ProviderStep step={entry.step} providers={state.providers} onDone={refresh} />
        ) : null}
        {!entry.registered ? (
          <p style={{ ...s.mutedStyle, marginTop: 12 }}>
            The gateway reports a step this build does not know how to render
            (<code style={{ fontFamily: 'var(--font-mono)' }}>{entry.id}</code>).
            Finish it in the terminal with{' '}
            <code style={{ fontFamily: 'var(--font-mono)' }}>seal tui</code>, then
            press Re-check.
          </p>
        ) : null}

        {reopenError !== null ? (
          <div role="alert" style={{ marginTop: 16 }}>
            <p style={{ ...s.errorStyle, fontWeight: 500 }}>
              The vault file cannot be opened with the recorded key.
            </p>
            <p style={{ ...s.mutedStyle, marginTop: 6 }}>{reopenError}</p>
            <p style={{ ...s.mutedStyle, marginTop: 6 }}>
              It was probably written by a different key. If it holds no secrets yet:
            </p>
            <pre style={{ ...s.monoStyle, marginTop: 8 }}>
              mv ~/.seal/config/vault/vault.age ~/.seal/config/vault/vault.age.bak
            </pre>
            <p style={{ ...s.mutedStyle, marginTop: 6 }}>
              Then press Re-check. If it does hold secrets, restore the matching
              identity file.
            </p>
          </div>
        ) : null}

        <div style={{ display: 'flex', gap: 8, marginTop: 20 }}>
          {barActions(entry.step).map((verb) => (
            <button
              key={verb}
              type="button"
              disabled={busy}
              onClick={() => { void dispatch(verb) }}
              className={s.primaryButtonClass}
            >
              {actionLabel(verb)}
            </button>
          ))}
        </div>
      </section>
    </div>
  )
}
