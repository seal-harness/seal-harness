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
}: {
  state: ParsedSetupState
  refresh: () => void
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
    return <SetupComplete onComplete={refresh} />
  }

  const entry = rail[index] ?? rail[0]
  if (entry === undefined) {
    return <SetupComplete onComplete={refresh} />
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
    <main className="mx-auto flex max-w-5xl gap-8 p-8">
      <nav aria-label="Setup steps" className="w-64 shrink-0">
        <ol className="space-y-2">
          {rail.map((item, i) => (
            <li key={item.id}>
              <button
                type="button"
                aria-current={i === index ? 'step' : undefined}
                onClick={() => setIndex(i)}
                className={`w-full rounded px-3 py-2 text-left text-sm ${
                  i === index ? 'bg-slate-700 text-slate-100' : 'text-slate-400'
                }`}
              >
                <span className="block font-medium">{item.title}</span>
                <span className="block text-xs">{item.step.status}</span>
              </button>
            </li>
          ))}
        </ol>
      </nav>

      <section className="min-w-0 flex-1">
        <h1
          ref={headingRef}
          tabIndex={-1}
          className="text-xl font-semibold text-slate-100 outline-none"
        >
          {entry.title}
        </h1>
        {entry.step.detail !== null ? (
          <p className="mt-2 text-sm text-slate-300" aria-live="polite">
            {entry.step.detail}
          </p>
        ) : null}
        {entry.step.status === 'blocked' ? (
          <p role="alert" className="mt-2 text-sm text-amber-300">
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
          <div className="mt-4 rounded border border-slate-700 p-4 text-sm text-slate-300">
            <p>
              The gateway reports a step this build does not know how to render
              (<code>{entry.id}</code>). Finish it in the terminal with
              <code> seal tui</code>, then press Re-check.
            </p>
          </div>
        ) : null}

        {reopenError !== null ? (
          <div role="alert" className="mt-4 rounded border border-red-700 p-4 text-sm text-red-200">
            <p className="font-medium">The vault file cannot be opened with the recorded key.</p>
            <p className="mt-2">{reopenError}</p>
            <p className="mt-2">
              It was probably written by a different key. If it holds no secrets yet:
            </p>
            <pre className="mt-2 overflow-x-auto rounded bg-slate-900 p-2 text-xs">
              mv ~/.seal/config/vault/vault.age ~/.seal/config/vault/vault.age.bak
            </pre>
            <p className="mt-2">Then press Re-check. If it does hold secrets, restore the matching identity file.</p>
          </div>
        ) : null}

        <div className="mt-6 flex gap-2">
          {barActions(entry.step).map((verb) => (
            <button
              key={verb}
              type="button"
              disabled={busy}
              onClick={() => { void dispatch(verb) }}
              className="rounded bg-emerald-700 px-3 py-2 text-sm text-white disabled:opacity-50"
            >
              {actionLabel(verb)}
            </button>
          ))}
        </div>
      </section>
    </main>
  )
}
