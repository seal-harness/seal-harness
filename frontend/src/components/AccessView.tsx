import { useCallback, useEffect, useMemo, useState } from 'react'
import {
  addedViaCopy,
  createPasskey,
  fetchAuthStatus,
  listCredentials,
  removeCredential,
  stepUpPasskey,
  verifyRegistration,
  type AuthStatus,
  type CredentialInfo,
} from '../lib/auth'
import { SignOutButton } from './SignOutButton'

// ── Helpers ─────────────────────────────────────────────────────────────

const labelStyle: React.CSSProperties = {
  fontSize: 12,
  fontWeight: 500,
  color: 'var(--text-muted)',
}

const inputStyle: React.CSSProperties = {
  fontSize: 14,
  padding: '6px 10px',
  backgroundColor: 'var(--bg-sunken)',
  border: '1px solid var(--border)',
  borderRadius: 'var(--radius-sm)',
  color: 'var(--text-primary)',
  outline: 'none',
  fontFamily: 'inherit',
  width: '100%',
}

const hintStyle: React.CSSProperties = {
  fontSize: 11,
  lineHeight: 1.5,
  color: 'var(--text-faint)',
  marginTop: 4,
}

const valueStyle: React.CSSProperties = {
  fontSize: 14,
  color: 'var(--text-primary)',
}

function Row({
  label, htmlFor, children, hint,
}: { label: string; htmlFor: string; children: React.ReactNode; hint?: React.ReactNode }) {
  return (
    <div style={{ display: 'grid', gridTemplateColumns: '140px 1fr', alignItems: 'start', gap: 12 }}>
      {htmlFor ? (
        <label htmlFor={htmlFor} style={labelStyle}>{label}</label>
      ) : (
        <span style={labelStyle}>{label}</span>
      )}
      <div>
        {children}
        {hint && <div style={hintStyle}>{hint}</div>}
      </div>
    </div>
  )
}

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

/** `YYYY-MM-DD`: a creation date only needs the day, and slicing keeps it
 *  locale-independent (so it reads the same in a test and on screen). */
function isoDate(iso: string): string {
  return /^\d{4}-\d{2}-\d{2}/.test(iso) ? iso.slice(0, 10) : iso
}

interface ArmedLink {
  url: string | null
  token: string
  expiresAt: string
}

/**
 * The Access view (`/access`): passkey CRUD, in the same two-pane shape as
 * Providers, Repos and Skills — every enrolled passkey in a list on the left,
 * and either the selected passkey's detail or the "New passkey" form on the
 * right.
 *
 * A passkey has no editable field, so the detail pane is read-only and the
 * only mutation is Delete (refused for the last passkey that can sign in
 * here). Creating one cannot happen on the server alone: the form's one field
 * is the **enrollment link**. "Create link" asks for an assertion from a
 * passkey that already works here — a session cookie alone can never mint
 * one — and arms a file-backed `ui_token` with a five-minute life. The link
 * is for whichever device should hold the new passkey, usually a phone or a
 * second laptop; "Add the passkey on this computer" is that same link used
 * locally, which is why the form offers it instead of a second ceremony.
 *
 * The link is shown once: the gateway stores only the token's digest, so a
 * reload cannot re-display it.
 *
 * Minting needs `passkey` mode and a usable credential; with nothing enrolled
 * there is nothing to step up with, so the form points at the terminal
 * instead. In `open` mode the gateway administers credentials
 * unauthenticated — that is what lets this page work there — so listing and
 * deletion succeed without a session. The list header carries the gateway's
 * mode and origin; the banners carry the states that change what the operator
 * can do.
 */
export function AccessView() {
  const [status, setStatus] = useState<AuthStatus | null>(null)
  const [creds, setCreds] = useState<CredentialInfo[]>([])
  const [loaded, setLoaded] = useState(false)
  const [loadError, setLoadError] = useState<string | null>(null)

  // Selection — the same shape as ProvidersView/ReposView.
  const [selectedId, setSelectedId] = useState<string | null>(null)
  const [creating, setCreating] = useState(false)
  const [confirmingDelete, setConfirmingDelete] = useState<string | null>(null)
  const [submitting, setSubmitting] = useState(false)

  // The new-passkey form's state: the armed link, plus its failure/feedback.
  const [link, setLink] = useState<ArmedLink | null>(null)
  const [grantOutstanding, setGrantOutstanding] = useState(false)
  const [formError, setFormError] = useState<string | null>(null)
  const [notice, setNotice] = useState<string | null>(null)
  const [ticks, setTicks] = useState(0)

  const load = useCallback(async () => {
    const [s, c] = await Promise.all([fetchAuthStatus(), listCredentials()])
    if (s.ok) setStatus(s.data)
    if (c.ok) setCreds(c.data)
    // Surface whichever half failed — the list is this pane's primary data, so
    // its failure wins over the status line's.
    setLoadError(!c.ok ? c.error : !s.ok ? s.error : null)
    setLoaded(true)
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

  const selected = useMemo(
    () => (selectedId ? creds.find((c) => c.id === selectedId) ?? null : null),
    [selectedId, creds],
  )

  // Design §9.4: the last *usable* credential cannot be removed. A credential
  // for another address is a safe removal even when it is the only one listed.
  const usable = creds.filter((c) => c.current).length
  const removeDisabled = (cred: CredentialInfo) => cred.current && usable <= 1

  const canMint = status?.state === 'passkey' && (status?.usable_credentials ?? 0) > 0

  /** Step up on an existing passkey, then ask the gateway for a portable grant. */
  const mint = useCallback(async (force: boolean) => {
    setSubmitting(true)
    setFormError(null)
    setNotice(null)
    const step = await stepUpPasskey('portable', force)
    setSubmitting(false)
    if (!step.ok) {
      setGrantOutstanding(step.code === 'grant_outstanding')
      setFormError(
        step.code === 'not_allowed'
          ? 'The confirmation prompt was cancelled or timed out.'
          : step.code === 'grant_outstanding'
            ? 'A link is already armed on this gateway. Press "Replace link" to mint a new one.'
            : step.error,
      )
      return
    }
    setGrantOutstanding(false)
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
    setSubmitting(true)
    setFormError(null)
    setNotice(null)
    const created = await createPasskey(link.token, 'add')
    if (!created.ok) {
      setSubmitting(false)
      setFormError(created.error)
      return
    }
    const verified = await verifyRegistration(created.data, link.token, true)
    setSubmitting(false)
    if (!verified.ok) {
      setFormError(verified.error)
      return
    }
    // The verify response names the credential that was just stored, so the
    // list can select it exactly like a create in the other CRUD views.
    const addedId = verified.data.credential ?? null
    setLink(null)
    setGrantOutstanding(false)
    setCreating(false)
    setSelectedId(addedId)
    setNotice('Passkey added.')
    await load()
  }, [link, load])

  const copyLink = useCallback(async () => {
    if (!link?.url) return
    setNotice(null)
    try {
      await navigator.clipboard.writeText(link.url)
      setNotice('Link copied.')
    } catch {
      // Non-secure contexts have no clipboard API; select the field instead so
      // copying by hand is one keystroke away.
      const el = document.getElementById('passkey-enroll-link') as HTMLInputElement | null
      el?.select()
      setNotice('Copy failed — the link is selected; copy it by hand.')
    }
  }, [link])

  const handleDelete = async (id: string) => {
    setFormError(null)
    setNotice(null)
    const res = await removeCredential(id)
    if (!res.ok) {
      setFormError(
        res.code === 'last_credential'
          ? 'That is the last passkey that can sign in here; add another first.'
          : res.error,
      )
      return
    }
    setConfirmingDelete(null)
    setSelectedId(null)
    await load()
  }

  const handleNew = () => {
    setConfirmingDelete(null)
    setSelectedId(null)
    setCreating(true)
    setLink(null)
    setGrantOutstanding(false)
    setFormError(null)
    setNotice(null)
    setTicks(0)
  }

  const handleCancel = () => {
    const hadLink = link !== null
    setCreating(false)
    setSelectedId(null)
    setFormError(null)
    setLink(null)
    setGrantOutstanding(false)
    // The grant is a server-side fact: hiding the form does not revoke it.
    setNotice(hadLink ? 'Enrollment link hidden — it stays valid until it expires.' : null)
  }

  const handleSelectPasskey = (id: string) => {
    if (confirmingDelete === id) setConfirmingDelete(null)
    setCreating(false)
    setLink(null)
    setGrantOutstanding(false)
    setFormError(null)
    setNotice(null)
    setSelectedId(id)
  }

  // ── Render ──────────────────────────────────────────────────────────
  return (
    <div className="flex flex-col flex-1 min-h-0" style={{ background: 'var(--bg-base)' }}>
      {status?.state === 'open' && (
        <div className="agate-banner" role="status" data-testid="access-open-banner">
          Access control is <strong>off</strong> — anyone who can reach this address has full
          control. Add a passkey to turn it on; you will be asked to sign in with it from then on.
        </div>
      )}
      {status?.rp_mismatch && (
        <div className="agate-banner" role="status" data-testid="access-rp-mismatch-banner">
          Every passkey listed here was registered for a different address and cannot sign you in
          on this one. Add a new passkey.
        </div>
      )}

      <div className="flex flex-1 min-h-0">
        {/* List pane */}
        <div
          className="shrink-0 flex flex-col"
          style={{
            width: 280,
            background: 'var(--bg-surface)',
            borderRight: '1px solid var(--border)',
          }}
        >
          <div className="px-3 py-2" style={{ borderBottom: '1px solid var(--border)' }}>
            <div className="flex items-center justify-between">
              <span
                className="text-xs font-semibold uppercase"
                style={{ color: 'var(--text-muted)', letterSpacing: '0.08em' }}
              >
                Passkeys ({creds.length})
              </span>
              <button
                type="button"
                className="btn btn-ghost flex items-center justify-center"
                style={{ width: 22, height: 22, padding: 0, fontSize: 14, lineHeight: 1 }}
                onClick={handleNew}
                aria-label="New passkey"
                title="New passkey"
                data-testid="passkey-new-btn"
              >
                +
              </button>
            </div>
            {/* The gateway's standing description: passkeys are bound to this
                address, so it stays visible next to the list. */}
            <div
              className="text-xs mt-1 truncate"
              style={{ color: 'var(--text-faint)' }}
              title={status?.origin ? `Passkeys are bound to ${status.origin}` : undefined}
              data-testid="passkey-mode"
            >
              {status ? `${status.state}${status.origin ? ` · ${status.origin}` : ''}` : '…'}
            </div>
          </div>

          <div className="flex-1 overflow-y-auto sidebar-scroll">
            {!loaded && (
              <div className="px-3 py-2 text-xs" style={{ color: 'var(--text-faint)' }}>
                Loading…
              </div>
            )}
            {loaded && loadError && (
              <div className="px-3 py-2 text-xs" style={{ color: 'var(--needs-input)' }}>
                Failed to load passkeys — the backend may be unreachable.
              </div>
            )}
            {loaded && !loadError && creds.length === 0 && (
              <div className="px-3 py-2 text-xs" style={{ color: 'var(--text-faint)' }}>
                No passkeys enrolled. Click + to add one.
              </div>
            )}
            {creds.map((c) => {
              const isActive = (creating ? false : selectedId === c.id) && !confirmingDelete
              return (
                <div
                  key={c.id}
                  data-testid={`passkey-row-${c.id}`}
                  className={`agent-row px-3 py-2 cursor-pointer${isActive ? ' selected' : ''}`}
                  onClick={() => handleSelectPasskey(c.id)}
                >
                  <div
                    className="text-sm truncate"
                    style={{ color: 'var(--text-primary)', letterSpacing: 'var(--tracking-tight)' }}
                    title={`${c.label || 'passkey'} · ${c.id}`}
                  >
                    {c.label || 'passkey'}
                    {/* The label is the same for every passkey, so the id
                        prefix is what tells two rows apart — and it matches
                        the first eight characters `seal access-control status`
                        prints. */}
                    {' '}
                    <span
                      style={{
                        fontSize: 11,
                        color: 'var(--text-faint)',
                        fontFamily: 'var(--font-mono)',
                      }}
                    >
                      {c.id.slice(0, 8)}
                    </span>
                  </div>
                  <div
                    className="text-xs mt-0.5 truncate"
                    style={{ color: 'var(--text-faint)' }}
                    title={`${c.rp_id} · ${addedViaCopy(c.added_via)}`}
                  >
                    {c.rp_id} · {addedViaCopy(c.added_via)}
                  </div>
                  {!c.current && (
                    <div className="text-xs mt-0.5" style={{ color: 'var(--needs-input)' }}>
                      cannot sign you in here — safe to remove
                    </div>
                  )}
                </div>
              )
            })}
          </div>

          {/* Sign out is a session action, not a passkey one, so it sits apart
              from the list rather than inside a passkey's detail pane. The
              button renders nothing when there is no passkey session. */}
          {status?.state === 'passkey' && status.authenticated && (
            <div className="px-3 py-2" style={{ borderTop: '1px solid var(--border)' }}>
              <SignOutButton className="w-full" />
            </div>
          )}
        </div>

        {/* Detail / editor pane */}
        <div className="flex-1 overflow-y-auto" style={{ padding: '24px 32px' }}>
          {!creating && !selected && (
            <div
              className="flex flex-col items-center justify-center"
              style={{ height: '100%', color: 'var(--text-faint)', gap: 8 }}
            >
              <div className="text-sm">Select a passkey to view it, or click + to add one.</div>
              {notice && (
                <div className="text-xs" data-testid="access-notice">{notice}</div>
              )}
            </div>
          )}

          {(creating || selected) && (
            <div
              className="flex flex-col gap-4"
              style={{ maxWidth: 720, margin: '0 auto' }}
              data-testid={creating ? 'passkey-form-new' : `passkey-form-${selectedId ?? ''}`}
            >
              <div className="flex items-center gap-2">
                <span className="text-lg font-semibold" style={{ color: 'var(--text-primary)' }}>
                  {creating
                    ? 'New passkey'
                    : selected ? `${selected.label || 'passkey'} ${selected.id.slice(0, 8)}` : 'Passkey'}
                </span>
                {!creating && selected && (
                  <span
                    className="pill"
                    style={{
                      background: 'var(--bg-elevated)',
                      color: selected.current ? 'var(--text-faint)' : 'var(--needs-input)',
                      fontSize: 11,
                      padding: '0 6px',
                    }}
                  >
                    {selected.current ? 'works at this address' : 'cannot sign you in here'}
                  </span>
                )}
              </div>

              {/* ── Create ─────────────────────────────────────────────── */}
              {creating && (
                <>
                  {!canMint && (
                    <p
                      data-testid="passkey-cannot-mint"
                      style={{ fontSize: 12, lineHeight: 1.5, color: 'var(--text-faint)' }}
                    >
                      A link has to be authorised by a passkey that already works here, so nothing
                      can be minted from this page yet. Run{' '}
                      <code>seal access-control enroll</code> in the terminal where Seal runs, then
                      add the passkey — the grant lasts five minutes.
                    </p>
                  )}

                  <Row
                    label="Enrollment link"
                    htmlFor="passkey-enroll-link"
                    hint={link
                      ? `Anyone who opens it can add a passkey to this gateway until it expires (in ${mmss(remaining)}). It is shown once — the gateway stores only its digest.`
                      : 'Create link asks you to confirm with a passkey that already works here, then arms a one-time link for the device that should hold the new passkey.'}
                  >
                    <div className="flex gap-2">
                      <input
                        id="passkey-enroll-link"
                        type="text"
                        readOnly
                        value={link?.url ?? ''}
                        placeholder="Not created yet"
                        aria-label="Enrollment link"
                        onFocus={(e) => e.currentTarget.select()}
                        style={inputStyle}
                      />
                      <button
                        type="button"
                        className="btn btn-ghost"
                        style={{ fontSize: 12, whiteSpace: 'nowrap' }}
                        onClick={() => { void copyLink() }}
                        disabled={!link?.url}
                        aria-label="Copy enrollment link"
                        title="Copy the enrollment link"
                        data-testid="passkey-copy-link"
                      >
                        Copy
                      </button>
                    </div>
                  </Row>

                  {link && !link.url && (
                    <Row
                      label="Enrollment token"
                      htmlFor="passkey-enroll-token"
                      hint={<>This gateway resolved no origin, so build the link yourself: <code>{'<your origin>'}/#enroll={'<token>'}</code></>}
                    >
                      <input
                        id="passkey-enroll-token"
                        type="text"
                        readOnly
                        value={link.token}
                        aria-label="Enrollment token"
                        onFocus={(e) => e.currentTarget.select()}
                        style={inputStyle}
                      />
                    </Row>
                  )}

                  {link && (
                    <p
                      data-testid="passkey-link-notes"
                      style={{ fontSize: 11, lineHeight: 1.5, color: 'var(--text-faint)' }}
                    >
                      Open the address exactly as written: a different scheme, port, or host
                      spelling registers a passkey that cannot sign in here. Clipboard managers
                      and cloud clipboard sync can read a copied link.
                      {isLoopbackOrigin(status?.origin) && (
                        <>
                          {' '}Seal is only reachable at <code>{status?.origin}</code>, so this
                          link opens in a browser on this computer. To enroll a phone, put Seal
                          behind an HTTPS origin and mint again.
                        </>
                      )}
                    </p>
                  )}
                </>
              )}

              {/* ── Read ───────────────────────────────────────────────── */}
              {!creating && selected && (
                <>
                  <Row
                    label="Id"
                    htmlFor=""
                    hint={<>The credential id the gateway stores. <code>seal access-control status</code> prints its first eight characters.</>}
                  >
                    <code
                      data-testid="passkey-detail-id"
                      style={{
                        fontSize: 12,
                        color: 'var(--text-primary)',
                        wordBreak: 'break-all',
                        userSelect: 'all',
                      }}
                    >
                      {selected.id}
                    </code>
                  </Row>

                  <Row label="Added" htmlFor="">
                    <div style={valueStyle}>{addedViaCopy(selected.added_via)}</div>
                  </Row>

                  <Row
                    label="Relying party"
                    htmlFor=""
                    hint={selected.current
                      ? 'A passkey only signs in at the address it was registered for.'
                      : 'A passkey only signs in at the address it was registered for. This one was registered elsewhere, so it cannot sign you in here — it is safe to delete.'}
                  >
                    <div style={valueStyle}>
                      {selected.rp_id}{' '}
                      <span
                        style={{
                          fontSize: 11,
                          color: selected.current ? 'var(--text-faint)' : 'var(--needs-input)',
                        }}
                      >
                        {selected.current ? '· current address' : '· cannot sign you in here'}
                      </span>
                    </div>
                  </Row>

                  <Row label="Sign count" htmlFor="" hint="How many times this passkey has signed in.">
                    <div style={valueStyle} data-testid="passkey-detail-sign-count">
                      {selected.sign_count}×
                    </div>
                  </Row>

                  <Row label="Created" htmlFor="">
                    <div style={valueStyle}>{isoDate(selected.created_at)}</div>
                  </Row>
                </>
              )}

              {formError && (
                <div
                  data-testid="passkey-form-error"
                  style={{ fontSize: 12, color: 'var(--needs-input)' }}
                >
                  {formError}
                </div>
              )}

              <div
                className="flex flex-col gap-2"
                style={{ borderTop: '1px solid var(--border)', paddingTop: 16 }}
              >
                {notice && (
                  <div
                    data-testid="access-notice"
                    style={{ fontSize: 12, color: 'var(--text-faint)' }}
                  >
                    {notice}
                  </div>
                )}
                {!creating && selected && removeDisabled(selected) && (
                  <div
                    data-testid="passkey-last-usable-hint"
                    style={{ fontSize: 12, color: 'var(--text-faint)' }}
                  >
                    This is the last passkey that can sign in here. Add another before deleting it.
                  </div>
                )}
                <div className="flex gap-2">
                  {creating && (link ? (
                    <button
                      type="button"
                      className="btn btn-primary px-3 py-2 rounded-lg text-sm font-medium"
                      onClick={() => { void addHere() }}
                      disabled={submitting || remaining === 0}
                      aria-label="Add the passkey on this computer"
                      data-testid="passkey-add-here"
                    >
                      {submitting ? 'Waiting for your passkey…' : 'Add the passkey on this computer'}
                    </button>
                  ) : (
                    <button
                      type="button"
                      className="btn btn-primary px-3 py-2 rounded-lg text-sm font-medium"
                      onClick={() => { void mint(grantOutstanding) }}
                      disabled={submitting || !canMint}
                      aria-label={grantOutstanding ? 'Replace enrollment link' : 'Create enrollment link'}
                      title={canMint ? undefined : 'Requires a passkey that already works here'}
                      data-testid="passkey-create"
                    >
                      {submitting ? 'Waiting for your passkey…' : grantOutstanding ? 'Replace link' : 'Create link'}
                    </button>
                  ))}
                  {creating && link && (
                    <button
                      type="button"
                      className="btn btn-ghost px-3 py-2 rounded-lg text-sm font-medium"
                      onClick={() => { void mint(true) }}
                      disabled={submitting}
                      aria-label="Replace enrollment link"
                      title="Replace this link with a new one"
                      data-testid="passkey-replace-link"
                    >
                      Replace link
                    </button>
                  )}
                  {creating && (
                    <button
                      type="button"
                      className="btn btn-ghost px-3 py-2 rounded-lg text-sm font-medium"
                      onClick={handleCancel}
                    >
                      Cancel
                    </button>
                  )}
                  {!creating && selected && confirmingDelete !== selected.id && (
                    <button
                      type="button"
                      className="btn btn-danger-ghost px-3 py-2 rounded-lg text-sm font-medium"
                      style={{ marginLeft: 'auto' }}
                      onClick={() => setConfirmingDelete(selected.id)}
                      disabled={removeDisabled(selected)}
                      aria-label="Delete passkey"
                      title={removeDisabled(selected)
                        ? 'Add another passkey before deleting the last one that can sign in'
                        : 'Delete this passkey'}
                      data-testid="passkey-delete"
                    >
                      Delete
                    </button>
                  )}
                </div>
                {!creating && selected && confirmingDelete === selected.id && (
                  <div className="flex flex-col gap-2" data-testid="passkey-delete-confirm">
                    <span className="text-sm" style={{ color: 'var(--needs-input)' }}>
                      Delete this passkey? A device that holds only this passkey will no longer be
                      able to sign in.
                    </span>
                    <div className="flex gap-2">
                      <button
                        type="button"
                        className="btn btn-danger-ghost px-3 py-2 rounded-lg text-sm font-medium"
                        style={{ background: 'var(--needs-input)', color: 'var(--text-primary)' }}
                        onClick={() => { void handleDelete(selected.id) }}
                        aria-label="Confirm delete"
                        data-testid="passkey-delete-confirm-btn"
                      >
                        Confirm delete
                      </button>
                      <button
                        type="button"
                        className="btn btn-ghost px-3 py-2 rounded-lg text-sm font-medium"
                        onClick={() => setConfirmingDelete(null)}
                      >
                        Cancel
                      </button>
                    </div>
                  </div>
                )}
              </div>
            </div>
          )}
        </div>
      </div>
    </div>
  )
}
