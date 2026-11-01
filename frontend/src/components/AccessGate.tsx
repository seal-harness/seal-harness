import { useCallback, useEffect, useRef, useState } from 'react'
import {
  clearEnrollToken,
  createPasskey,
  fetchAuthStatus,
  getPasskey,
  hasWebAuthn,
  isSecureContextOk,
  normaliseToken,
  readEnrollTokenFromHash,
  stepUpPasskey,
  storeEnrollToken,
  verifyLogin,
  verifyRegistration,
  type AccessState,
  type AuthStatus,
} from '../lib/auth'
import { AUTH_CHANGED_EVENT } from '../lib/unauthorized'

/**
 * The gate that stands in front of the whole app.
 *
 * The gate's decision is a function of one status payload (design §13):
 *
 * | state          | authenticated | usable | enrollment_via | renders          |
 * |----------------|---------------|--------|----------------|------------------|
 * | `passkey`      | yes           | >0     | any            | the app          |
 * | `open`         | –             | –      | any            | app + off banner |
 * | `passkey`      | no            | >0     | any            | login + token    |
 * | `unconfigured` | –             | 0      | `cli_token`    | setup + token    |
 * | `passkey`      | no            | 0      | `cli_token`    | re-enroll + token|
 * | either         | –             | –      | `none`         | setup, no field, |
 * |                |               |        |                | CLI hint + check |
 *
 * `enrollment_via: none` means no authority is armed, so a token field would be
 * a dead end: the operator mints one in the terminal and presses "Check again".
 *
 * Two prompts, deliberately distinct: the step-up ("Confirm it's you…") proves
 * an existing passkey, the create prompt adds a new one. A `step_up_required`
 * answer while authenticated restarts the whole add ceremony once, with the
 * returned 120 s grant; while unauthenticated it explains that a device which
 * already has a passkey must sign in first.
 */
export function AccessGate({ children }: { children: React.ReactNode }) {
  const [status, setStatus] = useState<AuthStatus | null>(null)
  const [loadFailed, setLoadFailed] = useState(false)
  const [enrollToken, setEnrollToken] = useState<string | null>(null)
  const [tokenInput, setTokenInput] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [recovery, setRecovery] = useState(false)
  const steppedUp = useRef(false)

  const refresh = useCallback(async () => {
    const res = await fetchAuthStatus()
    if (res.ok) {
      setStatus(res.data)
      setLoadFailed(false)
      if (res.data.state === 'passkey' && res.data.usable_credentials > 0) {
        // The token is spent once a usable credential exists.
        setEnrollToken(null)
        clearEnrollToken()
      }
    } else {
      setLoadFailed(true)
    }
  }, [])

  useEffect(() => {
    setEnrollToken(readEnrollTokenFromHash())
    void refresh()
  }, [refresh])

  useEffect(() => {
    const onAuthChanged = () => { void refresh() }
    // "Check again" without a button press: coming back to the window after
    // minting a token in the terminal re-reads the status (design §13.4).
    const onFocus = () => { void refresh() }
    window.addEventListener(AUTH_CHANGED_EVENT, onAuthChanged)
    window.addEventListener('focus', onFocus)
    return () => {
      window.removeEventListener(AUTH_CHANGED_EVENT, onAuthChanged)
      window.removeEventListener('focus', onFocus)
    }
  }, [refresh])

  const typedToken = normaliseToken(tokenInput)
  const effectiveToken = enrollToken ?? (typedToken || null)

  const runCeremony = useCallback(
    async (fn: () => Promise<{ ok: boolean; code?: string; error?: string }>) => {
      setBusy(true)
      setError(null)
      const res = await fn()
      setBusy(false)
      if (!res.ok) {
        setError(res.error ?? 'the passkey ceremony failed')
        if (res.code === 'not_allowed') setRecovery(true)
        if (res.code === 'grant_invalid') {
          // Stop sending a token the server rejected; keep the typed text so it
          // can be corrected (design §8.2).
          setEnrollToken(null)
          clearEnrollToken()
        }
        return false
      }
      return true
    },
    [],
  )

  /** Add a passkey, stepping up first when the gateway requires it. */
  const addPasskey = useCallback(async () => {
    const usable = status?.usable_credentials ?? 0
    const authenticated = status?.authenticated ?? false
    const target = usable > 0 ? 'add' : 'bootstrap'
    const token = effectiveToken
    if (token) storeEnrollToken(token)

    const created = await runCeremony(async () => {
      let attemptToken = token
      let options = await createPasskey(attemptToken, target)
      if (!options.ok) {
        if (options.code === 'step_up_required') {
          if (!authenticated) {
            return {
              ...options,
              error:
                'Sign in on a device that already has a passkey, or paste an enrollment ' +
                'token from `seal access-control enroll`.',
            }
          }
          if (steppedUp.current) {
            return { ...options, error: 'That took too long — try adding the passkey again.' }
          }
          steppedUp.current = true
          const step = await stepUpPasskey()
          if (!step.ok) return step
          attemptToken = step.data.grantToken
          options = await createPasskey(attemptToken, target)
        }
        if (!options.ok) return options
      }
      if (options.ok) {
        return verifyRegistration(options.data, attemptToken, target === 'add')
      }
      return options
    })
    steppedUp.current = false
    if (created) {
      setTokenInput('')
      setStatus(null)
      await refresh()
    }
  }, [status, effectiveToken, runCeremony, refresh])

  const signIn = useCallback(async () => {
    const ok = await runCeremony(async () => {
      const assertion = await getPasskey()
      if (!assertion.ok) return assertion
      return verifyLogin(assertion.data)
    })
    if (ok) {
      setStatus(null)
      await refresh()
    }
  }, [runCeremony, refresh])

  if (loadFailed) {
    return (
      <Panel title="Cannot reach the Seal gateway">
        <p className="agate-text">
          The page loaded but <code>/api/auth/status</code> did not answer. Check that
          <code> seal serve</code> is still running.
        </p>
        <button className="agate-primary" onClick={() => { void refresh() }}>Retry</button>
      </Panel>
    )
  }

  if (status === null) {
    return (
      <Panel title="Seal Harness">
        <p className="agate-text">Checking access control…</p>
      </Panel>
    )
  }

  if (status.state === 'passkey' && status.authenticated) {
    return <>{children}</>
  }

  if (status.state === 'open') {
    return (
      <>
        <div className="agate-banner" role="status">
          <strong>Access control is off.</strong> Anyone who can reach this address has full
          control of every session. Add a passkey in <em>Access</em> to turn it on.
        </div>
        {children}
      </>
    )
  }

  const tokenField = status.enrollment_via === 'none' ? null : (
    <TokenField
      value={tokenInput}
      onChange={setTokenInput}
      captured={enrollToken !== null}
      minted={status.enrollment_via === 'cli_token' || status.enrollment_via === 'cli_window'}
    />
  )

  const mintHint = (
    <div className="agate-note">
      <p>
        No enrollment token is armed. In the terminal where Seal runs, run
      </p>
      <p>
        <code>seal access-control enroll</code>
      </p>
      <p>then press “Check again” below. (Enrolling works while the daemon runs.)</p>
      <button className="agate-secondary" onClick={() => { void refresh() }}>
        Check again
      </button>
    </div>
  )

  // A passkey boot whose credentials are orphaned (the rpId moved) has nobody
  // who can sign in, so it goes to re-enrollment rather than the login screen.
  if (status.state === 'passkey' && status.usable_credentials > 0) {
    return (
      <Panel title="Sign in to Seal Harness">
        <p className="agate-text">
          This gateway is protected by a passkey. Use Touch ID, Windows Hello, or your
          security key.
        </p>
        <CapabilityNote surface="login" />
        <OriginNote status={status} />
        {error && <p className="agate-error">{error}</p>}
        <button
          className="agate-primary"
          disabled={busy || !canUsePasskey()}
          onClick={() => { void signIn() }}
        >
          {busy ? 'Waiting for your passkey…' : 'Sign in with a passkey'}
        </button>

        <details className="agate-waive">
          <summary>Enroll this device</summary>
          {tokenField ?? mintHint}
          <button
            className="agate-secondary"
            disabled={busy || !canUsePasskey() || effectiveToken === null}
            onClick={() => { void addPasskey() }}
          >
            {busy ? 'Waiting for your passkey…' : 'Enroll a passkey on this device'}
          </button>
        </details>

        {recovery && (
          <div className="agate-note">
            <p>
              No passkey on this device? Add one from a device that is already signed in
              (<em>Access</em>), or mint a token with
              <code> seal access-control enroll</code> and paste it above. If every passkey
              is lost, run <code>seal access-control reset --yes</code> (stop
              <code> seal serve</code> first).
            </p>
          </div>
        )}
        {!recovery && (
          <p className="agate-hint">
            Lost your only passkey? Run <code>seal access-control enroll</code> to add a new
            one, or <code>seal access-control reset --yes</code> (with the daemon stopped) to
            start over.
          </p>
        )}
      </Panel>
    )
  }

  // unconfigured, or a passkey boot whose credentials cannot sign in here.
  return (
    <Panel title={status.state === 'passkey' ? 'Register a new passkey' : 'Set up access control'}>
      {status.state === 'passkey' && (
        <p className="agate-error">
          The enrolled passkeys were registered for a different address
          (<code>{status.origin ?? 'unknown'}</code>), so they cannot be used here. Register a
          new one to continue.
        </p>
      )}
      <p className="agate-text">
        Seal is reachable over the network, and every session, transcript and slash command
        is behind this page. Protect it with a passkey.
      </p>
      <CapabilityNote surface="setup" />
      <OriginNote status={status} />

      {tokenField ?? mintHint}

      {error && <p className="agate-error">{error}</p>}

      <div className="agate-actions">
        <button
          className="agate-primary"
          disabled={busy || !canUsePasskey() || effectiveToken === null}
          onClick={() => { void addPasskey() }}
        >
          {busy ? 'Waiting for your passkey…' : 'Register a passkey'}
        </button>
      </div>

      <p className="agate-hint">
        Prefer to run without access control? Stop <code>seal serve</code> and run
        <code> seal access-control disable --yes</code>. Only the terminal can turn it off.
      </p>
    </Panel>
  )
}

function canUsePasskey(): boolean {
  return isSecureContextOk() && hasWebAuthn()
}

function TokenField({
  value,
  onChange,
  captured,
  minted,
}: {
  value: string
  onChange: (value: string) => void
  captured: boolean
  minted: boolean
}) {
  return (
    <label className="agate-field">
      <span>Enrollment token</span>
      <input
        value={value}
        onChange={(e) => onChange(e.target.value)}
        placeholder={captured ? 'already captured from the link' : 'printed by `seal access-control enroll`'}
        aria-label="Enrollment token"
      />
      <small>
        {minted
          ? 'A grant is armed on this gateway. Paste the token printed in the terminal (or follow the link it printed).'
          : 'Mint one with `seal access-control enroll` in the terminal where Seal runs.'}
      </small>
    </label>
  )
}

function CapabilityNote({ surface }: { surface: 'setup' | 'login' }) {
  if (canUsePasskey()) return null
  if (!isSecureContextOk()) {
    return (
      <p className="agate-note">
        Passkeys need HTTPS or <code>http://localhost</code>. This page is not a secure
        context, so the browser will not run a passkey ceremony.{' '}
        {surface === 'setup' ? (
          <>
            Run Seal behind a TLS reverse proxy (and set <code>[access_control] origin</code>{' '}
            to its https URL), or run <code>seal access-control disable --yes</code> in the
            terminal (stop <code>seal serve</code> first).
          </>
        ) : (
          <>Open the gateway over https or localhost.</>
        )}
      </p>
    )
  }
  return (
    <p className="agate-note">
      This browser does not support passkeys (<code>PublicKeyCredential</code> is missing),
      so the passkey option is unavailable.
    </p>
  )
}

function OriginNote({ status }: { status: AuthStatus }) {
  if (!status.origin) return null
  if (typeof window === 'undefined') return null
  const here = window.location.origin
  if (here === status.origin) return null
  return (
    <p className="agate-error">
      You opened <code>{here}</code>, but this gateway verifies <code>{status.origin}</code>.
      Open <a href={status.origin}>{status.origin}</a> instead.
    </p>
  )
}

function Panel({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <div className="agate-wrap">
      <div className="agate-panel">
        <h1 className="agate-title">{title}</h1>
        {children}
      </div>
    </div>
  )
}

/** Access state re-exported so the Access view can reuse the type. */
export type { AccessState }
