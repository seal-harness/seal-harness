import { useEffect, useRef, useState } from 'react'
import { useSetupState } from '../../hooks/useSetup'
import { SetupWizard } from './SetupWizard'

/**
 * The second gate: passkey access control first, then first-run setup.
 *
 * `main.tsx` renders `<AccessGate><SetupGate><App/></SetupGate></AccessGate>`,
 * so `App` never learns about setup and needs no `/api/setup` stub in its own
 * tests. Three outcomes:
 *
 * - `required_complete` **on first load** → the app (a configured operator must
 *   never see the wizard);
 * - completion reached *while the wizard is on screen* → the completion screen,
 *   and only "Start chatting" reveals the app. Revealing it the moment the
 *   server flips `required_complete` would snatch the confirmation away before
 *   it could be read (and made the completion screen unreachable — the e2e
 *   caught it);
 * - a 403 → "setup has to run on the host" (the middleware refuses setup
 *   before access control is configured; that is a different problem from a
 *   missing vault, and mixing them would send the operator in circles);
 * - anything else (network, malformed payload) → **fail closed** with Retry.
 *   A wizard that silently rendered the app on a probe error would look fine
 *   and then fail on the first message.
 */
export function SetupGate({ children }: { children: React.ReactNode }) {
  const { state, status, error, hint, reload } = useSetupState()
  // Did this visit *start* incomplete? Captured once, on the first payload: a
  // returning operator (already complete) goes straight to the app, while a
  // first run keeps the wizard mounted so the completion screen can be read.
  const [startedIncomplete, setStartedIncomplete] = useState<boolean | null>(null)
  const firstPayload = useRef(true)
  const [confirmed, setConfirmed] = useState(false)

  useEffect(() => {
    if (!firstPayload.current || state === null) return
    firstPayload.current = false
    setStartedIncomplete(!state.required_complete)
  }, [state])

  if (state !== null && state.required_complete && (confirmed || startedIncomplete !== true)) {
    return <>{children}</>
  }

  if (status === 403) {
    return (
      <main className="mx-auto max-w-2xl p-8">
        <h1 className="text-xl font-semibold text-slate-100">Finish access setup first</h1>
        <p role="alert" className="mt-3 text-sm text-slate-300">
          The gateway is refusing setup requests until passkey access control is configured.
          {hint !== null ? ` ${hint}` : ''}
        </p>
        <p className="mt-3 text-sm text-slate-400">
          Run the enrollment steps in the terminal, then reload this page.
        </p>
      </main>
    )
  }

  if (state === null) {
    if (error !== null) {
      return (
        <main className="mx-auto max-w-2xl p-8">
          <h1 className="text-xl font-semibold text-slate-100">Setup status unavailable</h1>
          <p role="alert" className="mt-3 text-sm text-slate-300">{error}</p>
          {hint !== null ? <p className="mt-2 text-sm text-slate-400">{hint}</p> : null}
          <button
            type="button"
            onClick={reload}
            className="mt-4 rounded bg-slate-700 px-3 py-2 text-sm text-slate-100"
          >
            Retry
          </button>
        </main>
      )
    }
    return (
      <main className="mx-auto max-w-2xl p-8 text-sm text-slate-400" aria-live="polite">
        Checking setup…
      </main>
    )
  }

  return <SetupWizard state={state} refresh={reload} onComplete={() => setConfirmed(true)} />
}
