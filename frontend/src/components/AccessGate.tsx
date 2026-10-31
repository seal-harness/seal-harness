import { useCallback, useEffect, useState } from 'react'
import {
  createPasskey,
  fetchAuthStatus,
  getPasskey,
  hasWebAuthn,
  isSecureContextOk,
  normaliseCode,
  readSetupCodeFromHash,
  storeSetupCode,
  verifyLogin,
  verifyRegistration,
  waive,
  type AccessState,
  type AuthStatus,
} from '../lib/auth'
import { AUTH_CHANGED_EVENT } from '../lib/unauthorized'

/**
 * The gate that stands in front of the whole app.
 *
 * Three states, from `/api/auth/status`:
 *
 * | state          | renders                                             |
 * |----------------|-----------------------------------------------------|
 * | `unconfigured` | the setup screen (enroll a passkey, or waive)       |
 * | `open`         | the app, with a persistent "access control is off"  |
 * |                | banner                                              |
 * | `passkey`      | the login screen, or the app once authenticated     |
 *
 * A 401 from anywhere in the app — and an explicit sign-out — dispatches
 * `seal-auth-changed`; the gate then
 * re-fetches the status and re-applies the table above rather than assuming
 * "login" (after a `reset --yes` + restart the state is `unconfigured`, and no
 * further 401 will fire).
 */
export function AccessGate({ children }: { children: React.ReactNode }) {
  const [status, setStatus] = useState<AuthStatus | null>(null)
  const [loadFailed, setLoadFailed] = useState(false)
  const [setupCode, setSetupCode] = useState<string | null>(null)
  const [codeInput, setCodeInput] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [recovery, setRecovery] = useState(false)

  const refresh = useCallback(async () => {
    const res = await fetchAuthStatus()
    if (res.ok) {
      setStatus(res.data)
      setLoadFailed(false)
      if (res.data.state !== 'unconfigured' && !res.data.rp_mismatch) {
        // The setup code is spent once setup completes.
        setSetupCode(null)
      }
    } else {
      setLoadFailed(true)
    }
  }, [])

  useEffect(() => {
    const fromHash = readSetupCodeFromHash()
    setSetupCode(fromHash)
    void refresh()
  }, [refresh])

  useEffect(() => {
    const onAuthChanged = () => { void refresh() }
    window.addEventListener(AUTH_CHANGED_EVENT, onAuthChanged)
    return () => window.removeEventListener(AUTH_CHANGED_EVENT, onAuthChanged)
  }, [refresh])

  const runCeremony = useCallback(
    async (fn: () => Promise<{ ok: boolean; code?: string; error?: string }>) => {
      setBusy(true)
      setError(null)
      const res = await fn()
      setBusy(false)
      if (!res.ok) {
        setError(res.error ?? 'the passkey ceremony failed')
        if (res.code === 'not_allowed') setRecovery(true)
        return false
      }
      return true
    },
    [],
  )

  const enroll = useCallback(async () => {
    const code = (setupCode ?? normaliseCode(codeInput)) || null
    if (code) storeSetupCode(code)
    const created = await runCeremony(async () => {
      const c = await createPasskey(code)
      if (!c.ok) return c
      return verifyRegistration(c.data, code)
    })
    if (created) {
      setStatus(null)
      await refresh()
    }
  }, [setupCode, codeInput, runCeremony, refresh])

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

  const doWaive = useCallback(async () => {
    const code = (setupCode ?? normaliseCode(codeInput)) || null
    const ok = await runCeremony(async () => waive(code))
    if (ok) {
      setStatus(null)
      await refresh()
    }
  }, [setupCode, codeInput, runCeremony, refresh])

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

  // A passkey boot whose credentials are orphaned (the rpId moved) has nobody
  // who can sign in, so it goes to re-enrollment rather than the login screen.
  if (status.state === 'passkey' && !status.rp_mismatch) {
    return (
      <Panel title="Sign in to Seal Harness">
        <p className="agate-text">
          This gateway is protected by a passkey. Use Touch ID, Windows Hello, or your
          security key.
        </p>
        <CapabilityNote />
        <OriginNote status={status} />
        {error && <p className="agate-error">{error}</p>}
        <button className="agate-primary" disabled={busy || !canUsePasskey()} onClick={() => { void signIn() }}>
          {busy ? 'Waiting for your passkey…' : 'Sign in with a passkey'}
        </button>
        {recovery && (
          <div className="agate-note">
            <p>
              No passkey on this device? Add one from a device that is already signed in
              (<em>Access</em>), or run
              <code> seal access-control reset --yes</code> in the terminal where Seal is
              running — that clears the existing passkeys so you can enroll again.
            </p>
          </div>
        )}
        {!recovery && (
          <p className="agate-hint">
            Lost your only passkey? Run <code>seal access-control reset --yes</code> in the
            terminal where Seal is running.
          </p>
        )}
      </Panel>
    )
  }

  // state === 'unconfigured' (or a passkey boot whose credentials are orphaned)
  const needsCode = true
  const passkeyUsable = canUsePasskey()
  return (
    <Panel title={status.rp_mismatch ? 'Register a new passkey' : 'Set up access control'}>
      {status.rp_mismatch && (
        <p className="agate-error">
          The enrolled passkeys were registered for a different address
          (<code>{status.origin ?? 'unknown'}</code>), so they cannot be used here. Register a
          new one to continue.
        </p>
      )}
      <p className="agate-text">
        Seal is reachable over the network, and every session, transcript and slash command
        is behind this page. Protect it with a passkey, or explicitly run without one.
      </p>
      <CapabilityNote />
      <OriginNote status={status} />

      {needsCode && (
        <label className="agate-field">
          <span>Setup code</span>
          <input
            value={codeInput}
            onChange={(e) => setCodeInput(e.target.value)}
            placeholder={setupCode ? 'already captured from the banner link' : 'printed by `seal serve`'}
            aria-label="Setup code"
          />
          <small>
            Printed in the terminal where you ran <code>seal serve</code>
            {setupCode ? ' (and captured from the link you followed).' : '.'} If you lost it,
            restart <code>seal serve</code> for a fresh one.
          </small>
        </label>
      )}

      {error && <p className="agate-error">{error}</p>}

      <div className="agate-actions">
        <button
          className="agate-primary"
          disabled={busy || !passkeyUsable || !(setupCode || codeInput.trim())}
          onClick={() => { void enroll() }}
        >
          {busy ? 'Waiting for your passkey…' : 'Register a passkey'}
        </button>
      </div>

      <details className="agate-waive">
        <summary>Run without access control</summary>
        <p>
          Anyone who can reach this address gets full control of every session: messages the
          agent will execute, every transcript, every slash command. This choice is recorded
          in <code>~/.seal/security.toml</code>. Undo it with
          <code> seal access-control reset --yes</code>.
        </p>
        <label className="agate-check">
          <input type="checkbox" id="agate-confirm" />
          <span>I understand this gateway will accept unauthenticated requests.</span>
        </label>
        <button
          className="agate-danger"
          disabled={busy || !(setupCode || codeInput.trim())}
          onClick={(e) => {
            const box = (e.currentTarget.previousElementSibling as HTMLElement | null)
              ?.querySelector('input[type="checkbox"]') as HTMLInputElement | null
            if (!box?.checked) {
              setError('Tick the confirmation box first.')
              return
            }
            void doWaive()
          }}
        >
          Waive access control
        </button>
      </details>
    </Panel>
  )
}

function canUsePasskey(): boolean {
  return isSecureContextOk() && hasWebAuthn()
}

function CapabilityNote() {
  if (canUsePasskey()) return null
  if (!isSecureContextOk()) {
    return (
      <p className="agate-note">
        Passkeys need HTTPS or <code>http://localhost</code>. This page is not a secure
        context, so the browser will not run a passkey ceremony. Run Seal behind a TLS
        reverse proxy (and set <code>[access_control] origin</code> to its https URL), or
        continue without access control.
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
