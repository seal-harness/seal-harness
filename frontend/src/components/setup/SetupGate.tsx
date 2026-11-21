import { useEffect, useRef, useState } from 'react'
import logoImg from '../../../assets/SealLogo.png'
import { useSetupState } from '../../hooks/useSetup'
import { SetupWizard } from './SetupWizard'
import * as s from './styles'

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
 *
 * The page chrome (logo, title, centred column) lives here so every state —
 * wizard, completion, refusal, error — carries the same identity.
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

  return (
    <div style={s.pageStyle}>
      <div style={s.shellStyle}>
        <header style={s.headerStyle}>
          <img src={logoImg} alt="" style={s.logoStyle} />
          <div>
            <h1 style={s.titleStyle}>Seal Harness Setup Wizard</h1>
            <p style={s.subtitleStyle}>
              Seal keeps your API keys and tokens in an encrypted vault, and
              talks to the model provider you choose. Two steps, then you are in.
            </p>
          </div>
        </header>

        <div style={{ marginTop: 20 }}>
          {status === 403 ? (
            <div style={s.cardStyle}>
              <h2 style={s.sectionTitleStyle}>Finish access setup first</h2>
              <p role="alert" style={{ ...s.warningStyle, marginTop: 8 }}>
                The gateway is refusing setup requests until passkey access
                control is configured.{hint !== null ? ` ${hint}` : ''}
              </p>
              <p style={{ ...s.mutedStyle, marginTop: 8 }}>
                Run the enrollment steps in the terminal, then reload this page.
              </p>
            </div>
          ) : state === null ? (
            error !== null ? (
              <div style={s.cardStyle}>
                <h2 style={s.sectionTitleStyle}>Setup status unavailable</h2>
                <p role="alert" style={{ ...s.errorStyle, marginTop: 8 }}>{error}</p>
                {hint !== null ? <p style={{ ...s.mutedStyle, marginTop: 4 }}>{hint}</p> : null}
                <button type="button" onClick={reload} className={s.ghostButtonClass} style={{ marginTop: 12 }}>
                  Retry
                </button>
              </div>
            ) : (
              <p style={s.mutedStyle} aria-live="polite">Checking setup…</p>
            )
          ) : (
            <SetupWizard
              state={state}
              refresh={reload}
              onComplete={() => setConfirmed(true)}
            />
          )}
        </div>
      </div>
    </div>
  )
}
