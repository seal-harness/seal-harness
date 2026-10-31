import { useCallback, useEffect, useState } from 'react'
import {
  createPasskey,
  fetchAuthStatus,
  listCredentials,
  logout,
  removeCredential,
  verifyRegistration,
  type AuthStatus,
  type CredentialInfo,
} from '../lib/auth'
import { notifyAuthChanged } from '../lib/unauthorized'

/**
 * The Access view (`/access`): the mode, the enrolled passkeys, and the two
 * actions that change them.
 *
 * It is reachable from the top bar so a second device never needs a terminal
 * round trip — "add a passkey" from a laptop that is already signed in is the
 * normal way to enroll a phone.
 */
export function AccessView() {
  const [status, setStatus] = useState<AuthStatus | null>(null)
  const [creds, setCreds] = useState<CredentialInfo[]>([])
  const [error, setError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const [setupCode, setSetupCode] = useState('')

  const load = useCallback(async () => {
    const [s, c] = await Promise.all([fetchAuthStatus(), listCredentials()])
    if (s.ok) setStatus(s.data)
    if (c.ok) setCreds(c.data)
    else setError(c.error)
  }, [])

  useEffect(() => { void load() }, [load])

  const add = useCallback(async () => {
    setBusy(true)
    setError(null)
    const code = setupCode.trim() || null
    const created = await createPasskey(code)
    if (!created.ok) {
      setBusy(false)
      if (created.code === 'not_allowed') {
        setError('The passkey prompt was cancelled or timed out.')
        return
      }
      setError(created.error)
      return
    }
    const verified = await verifyRegistration(created.data, code, true)
    setBusy(false)
    if (!verified.ok) {
      setError(verified.error)
      return
    }
    setSetupCode('')
    await load()
  }, [setupCode, load])

  const remove = useCallback(async (id: string) => {
    setError(null)
    const res = await removeCredential(id)
    if (!res.ok) {
      setError(res.error)
      return
    }
    await load()
  }, [load])

  const needsCode = status !== null && status.state !== 'passkey'

  return (
    <div className="agate-wrap">
      <div className="agate-panel">
        <h1 className="agate-title">Access control</h1>

        <p className="agate-text">
          Mode: <strong>{status?.state ?? '…'}</strong>
          {status?.origin ? <> · verified origin <code>{status.origin}</code></> : null}
          {status?.rp_id ? <> · rp id <code>{status.rp_id}</code></> : null}
        </p>

        {status?.state === 'open' && (
          <p className="agate-note">
            Access control is currently <strong>off</strong>. Anyone who can reach this
            address has full control. Register a passkey below to turn it on — you will be
            asked to sign in with it from then on.
          </p>
        )}

        {status?.rp_mismatch && (
          <p className="agate-error">
            The listed passkeys were registered for a different address and cannot be used
            here. Register a new one.
          </p>
        )}

        {status?.state === 'unconfigured' && (
          <p className="agate-note">
            No access control has been configured yet. Register a passkey below, or open the
            setup screen.
          </p>
        )}

        <ul className="agate-creds">
          {creds.length === 0 && <li className="agate-hint">No passkeys enrolled.</li>}
          {creds.map((c) => (
            <li key={c.id}>
              <div>
                <strong>{c.label}</strong>{' '}
                <span className="agate-hint">
                  {c.created_at} · rp_id={c.rp_id} · used {c.sign_count}×
                  {c.current ? ' · current address' : ' · other address'}
                </span>
              </div>
              <button
                className="agate-danger"
                onClick={() => { void remove(c.id) }}
                disabled={status?.state === 'passkey' && creds.length <= 1}
                title={
                  status?.state === 'passkey' && creds.length <= 1
                    ? 'Add another passkey before removing the only one'
                    : 'Remove this passkey'
                }
              >
                Remove
              </button>
            </li>
          ))}
        </ul>

        {needsCode && (
          <label className="agate-field">
            <span>Setup code</span>
            <input
              value={setupCode}
              onChange={(e) => setSetupCode(e.target.value)}
              placeholder="printed by `seal serve`"
            />
            <small>
              Required while access control is off: it is what stops a remote client from
              enrolling its own passkey and taking over.
            </small>
          </label>
        )}

        {error && <p className="agate-error">{error}</p>}

        <div className="agate-actions">
          <button className="agate-primary" disabled={busy} onClick={() => { void add() }}>
            {busy ? 'Waiting for your passkey…' : 'Add a passkey'}
          </button>
          {status?.state === 'passkey' && status.authenticated && (
            <button
              className="agate-danger"
              onClick={() => {
                void (async () => {
                  await logout()
                  notifyAuthChanged()
                  // Closes the already-authorised WebSocket and clears every
                  // in-memory transcript — see SignOutButton.
                  window.location.reload()
                })()
              }}
            >
              Sign out
            </button>
          )}
        </div>
      </div>
    </div>
  )
}
