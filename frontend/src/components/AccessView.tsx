import { useCallback, useEffect, useMemo, useState } from 'react'
import {
  addedViaCopy,
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

/** True when `origin` only resolves on this machine. */
function isLoopbackOrigin(origin: string | null | undefined): boolean {
  if (!origin) return false
  try {
    const host = new URL(origin).hostname
    return host === 'localhost' || host === '127.0.0.1' || host === '::1'
  } catch {
    return false
  }
}

function mmss(totalSeconds: number): string {
  const s = Math.max(0, totalSeconds)
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`
}

interface ArmedLink {
  url: string | null
  token: string
  expiresAt: string
}

/**
 * The Access view (`/access`): the mode, the enrolled passkeys, and the actions
 * that change them.
 *
 * "Add a passkey" mints a **link** rather than running a ceremony here, because
 * the passkey an operator adds is usually for a different device — a phone, a
 * second laptop. The grant behind the link is a file-backed `ui_token` with a
 * five-minute life, minted only after a step-up assertion from a passkey on
 * this device, so a session cookie alone can never produce one.
 *
 * The link is shown once: the gateway stores only the token's digest, so a
 * reload cannot re-display it. "Add the passkey on this computer" is the same
 * link used locally, which is why the panel offers it instead of a second
 * ceremony.
 *
 * Minting needs `passkey` mode and a usable credential; with nothing enrolled
 * there is nothing to step up with, so the panel points at the terminal
 * instead. In `open` mode the gateway administers credentials unauthenticated
 * — that is what lets this page work there — so listing and removal succeed
 * without a session.
 */
export function AccessView() {
  const [status, setStatus] = useState<AuthStatus | null>(null)
  const [creds, setCreds] = useState<CredentialInfo[]>([])
  const [error, setError] = useState<string | null>(null)
  const [notice, setNotice] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const [link, setLink] = useState<ArmedLink | null>(null)
  const [ticks, setTicks] = useState(0)

  const load = useCallback(async () => {
    const [s, c] = await Promise.all([fetchAuthStatus(), listCredentials()])
    if (s.ok) setStatus(s.data)
    if (c.ok) setCreds(c.data)
    else setError(c.error)
  }, [])

  useEffect(() => { void load() }, [load])

  // The countdown is advisory: it is computed against this browser's clock, so
  // it clamps at zero rather than claiming the grant is dead, and the link
  // stays on screen if it does.
  useEffect(() => {
    if (!link) return
    const id = setInterval(() => setTicks((t) => t + 1), 1000)
    return () => clearInterval(id)
  }, [link])

  const remaining = useMemo(() => {
    void ticks
    if (!link) return 0
    const ms = Date.parse(link.expiresAt) - Date.now()
    return Number.isFinite(ms) ? Math.max(0, Math.floor(ms / 1000)) : 0
  }, [link, ticks])

  const canMint = status?.state === 'passkey' && (status?.usable_credentials ?? 0) > 0

  /** Step up on an existing passkey, then ask the gateway for a portable grant. */
  const mint = useCallback(async (force: boolean) => {
    setBusy(true)
    setError(null)
    setNotice(null)
    const step = await stepUpPasskey('portable', force)
    setBusy(false)
    if (!step.ok) {
      setError(
        step.code === 'not_allowed'
          ? 'The confirmation prompt was cancelled or timed out.'
          : step.code === 'grant_outstanding'
            ? 'A link is already armed on this gateway. Press "Replace" to mint a new one.'
            : step.error,
      )
      return
    }
    setLink({
      url: step.data.url,
      token: step.data.grantToken,
      expiresAt: step.data.expiresAt,
    })
    setTicks(0)
  }, [])

  /** Add the passkey here, using the very link that is on screen. */
  const addHere = useCallback(async () => {
    if (!link) return
    setBusy(true)
    setError(null)
    setNotice(null)
    const created = await createPasskey(link.token, 'add')
    if (!created.ok) {
      setBusy(false)
      setError(created.error)
      return
    }
    const verified = await verifyRegistration(created.data, link.token, true)
    setBusy(false)
    if (!verified.ok) {
      setError(verified.error)
      return
    }
    setLink(null)
    setNotice('Passkey added.')
    await load()
  }, [link, load])

  const copyLink = useCallback(async () => {
    if (!link?.url) return
    try {
      await navigator.clipboard.writeText(link.url)
      setNotice('Link copied.')
    } catch {
      setNotice('Copy failed — select the link and copy it by hand.')
    }
  }, [link])

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
          {status?.origin ? (<> · verified origin <code>{status.origin}</code></>) : null}
          {status?.rp_id ? (<> · rp id <code>{status.rp_id}</code></>) : null}
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

        {!canMint && (
          <p className="agate-note">
            A link has to be authorised by a passkey that already works here, so nothing can
            be minted from this page yet. Run{' '}
            <code>seal access-control enroll</code> in the terminal where Seal runs, then add
            the passkey — the grant lasts five minutes.
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

        {link ? (
          <div className="agate-note">
            <p>
              Open this link in a browser on the device that should hold the new passkey.
              Anyone who opens it can add a passkey to this gateway until it expires, and it
              can only be shown once.
            </p>
            {link.url ? (
              <>
                <label className="agate-field">
                  <span>Enrollment link</span>
                  <input readOnly value={link.url} aria-label="Enrollment link" onFocus={(e) => e.currentTarget.select()} />
                </label>
                <button className="agate-secondary" onClick={() => { void copyLink() }}>
                  Copy link
                </button>
              </>
            ) : (
              <label className="agate-field">
                <span>Enrollment token</span>
                <input readOnly value={link.token} aria-label="Enrollment token" onFocus={(e) => e.currentTarget.select()} />
                <small>
                  This gateway resolved no origin, so build the link yourself:
                  <code>{'<your origin>'}/#enroll={'<token>'}</code>
                </small>
              </label>
            )}
            <p className="agate-hint">
              Expires in {mmss(remaining)}.
              {isLoopbackOrigin(status?.origin) && (
                <>
                  {' '}Seal is only reachable at <code>{status?.origin}</code>, so this link
                  opens in a browser on this computer. To enroll a phone, put Seal behind an
                  HTTPS origin and mint again.
                </>
              )}
            </p>
            <p className="agate-hint">
              Open the address exactly as written: a different scheme, port, or host spelling
              registers a passkey that cannot sign in here. Clipboard managers and cloud
              clipboard sync can read a copied link.
            </p>

            <div className="agate-actions">
              <button
                className="agate-primary"
                disabled={busy || remaining === 0}
                onClick={() => { void addHere() }}
              >
                {busy ? 'Waiting for your passkey…' : 'Add the passkey on this computer'}
              </button>
              <button
                className="agate-secondary"
                disabled={busy}
                onClick={() => { void mint(true) }}
                title="Replace this link with a new one"
              >
                Replace
              </button>
              <button
                className="agate-secondary"
                disabled={busy}
                onClick={() => { setLink(null); setNotice('Link discarded. It stays valid until it expires.') }}
              >
                Hide
              </button>
            </div>
          </div>
        ) : (
          <div className="agate-actions">
            <button
              className="agate-primary"
              disabled={busy || !canMint}
              onClick={() => { void mint(false) }}
              title={canMint ? undefined : 'Requires a passkey that already works here'}
            >
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
        )}
      </div>
    </div>
  )
}
