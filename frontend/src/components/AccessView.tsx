import { useCallback, useEffect, useState } from 'react'
import {
  addedViaCopy,
  clearEnrollToken,
  createPasskey,
  fetchAuthStatus,
  listCredentials,
  logout,
  removeCredential,
  stepUpPasskey,
  verifyRegistration,
  type AuthStatus,
  type CredentialInfo,
} from '../lib/auth'
import { notifyAuthChanged } from '../lib/unauthorized'

/**
 * The Access view (`/access`): the mode, the enrolled passkeys, and the actions
 * that change them.
 *
 * Adding a passkey here is the normal way to enroll a second device: with a
 * usable credential enrolled the flow proves it first (`enroll/options` →
 * assertion → 120 s grant), then registers the new key with that grant. With
 * nothing usable enrolled it falls back to the bootstrap path, which needs a
 * token from `seal access-control enroll`.
 *
 * In `open` mode the gateway administers credentials unauthenticated — that is
 * what lets this page work at all there — so `listCredentials` and removal
 * succeed without a session.
 */
export function AccessView() {
  const [status, setStatus] = useState<AuthStatus | null>(null)
  const [creds, setCreds] = useState<CredentialInfo[]>([])
  const [error, setError] = useState<string | null>(null)
  const [notice, setNotice] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)

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
    setNotice(null)
    const usable = status?.usable_credentials ?? 0
    const target = usable > 0 ? 'add' : 'bootstrap'

    let token: string | null = null
    if (usable > 0) {
      // Two distinct prompts, in order: "confirm it's you" then "create".
      const step = await stepUpPasskey()
      if (!step.ok) {
        setBusy(false)
        setError(
          step.code === 'not_allowed'
            ? 'The confirmation prompt was cancelled or timed out.'
            : step.error,
        )
        return
      }
      token = step.data.grantToken
    }

    const created = await createPasskey(token, target)
    if (!created.ok) {
      setBusy(false)
      setError(
        created.code === 'grant_required'
          ? 'Adding a passkey needs a token from `seal access-control enroll`.'
          : created.error,
      )
      return
    }
    const verified = await verifyRegistration(created.data, token, target === 'add')
    setBusy(false)
    if (!verified.ok) {
      setError(verified.error)
      return
    }
    clearEnrollToken()
    setNotice('Passkey added.')
    await load()
  }, [status, load])

  const remove = useCallback(async (id: string) => {
    setError(null)
    setNotice(null)
    const res = await removeCredential(id)
    if (!res.ok) {
      setError(
        res.code === 'last_credential'
          ? 'That is the last passkey that can sign in here; add another first.'
          : res.error,
      )
      return
    }
    await load()
  }, [load])

  // Design §9.4: the last *usable* credential cannot be removed. A credential
  // for another address is a safe removal even when it is the only one listed.
  const usable = creds.filter((c) => c.current).length
  const removeDisabled = (cred: CredentialInfo) => cred.current && usable <= 1

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

        {status?.enrollment_via === 'none' && (
          <p className="agate-note">
            No enrollment token is armed. Run <code>seal access-control enroll</code> in the
            terminal where Seal runs, then add the passkey — the grant lasts ten minutes.
          </p>
        )}

        <ul className="agate-creds">
          {creds.length === 0 && <li className="agate-hint">No passkeys enrolled.</li>}
          {creds.map((c) => (
            <li key={c.id}>
              <div>
                <strong>{c.label}</strong>{' '}
                <span className="agate-hint">
                  {addedViaCopy(c.added_via)} · rp_id={c.rp_id} · used {c.sign_count}×
                  {c.current ? ' · current address' : ' · cannot sign you in here; safe to remove'}
                </span>
              </div>
              <button
                className="agate-danger"
                onClick={() => { void remove(c.id) }}
                disabled={removeDisabled(c)}
                title={
                  removeDisabled(c)
                    ? 'Add another passkey before removing the last one that can sign in'
                    : 'Remove this passkey'
                }
              >
                Remove
              </button>
            </li>
          ))}
        </ul>

        {error && <p className="agate-error">{error}</p>}
        {notice && <p className="agate-hint">{notice}</p>}

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
