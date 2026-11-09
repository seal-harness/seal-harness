import { useEffect, useMemo, useRef, useState } from 'react'
import type { ChannelInput, ChannelUpdateInput, ChannelAuthStatus } from '../types'
import {
  createChannel,
  deleteChannel,
  updateChannel,
  useChannels,
} from '../hooks/useApi'

// ── Helpers ─────────────────────────────────────────────────────────────

const AUTH_STATUS_LABELS: Record<ChannelAuthStatus, string> = {
  'configured': 'Configured',
  'missing-credential': 'Missing Credential',
  'vault-locked': 'Vault Locked',
}

const KIND_LABELS: Record<string, string> = {
  signal: 'Signal',
  telegram: 'Telegram',
}

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

function Row({
  label, htmlFor, children, hint,
}: { label: string; htmlFor: string; children: React.ReactNode; hint?: string }) {
  return (
    <div style={{ display: 'grid', gridTemplateColumns: '140px 1fr', alignItems: 'start', gap: 12 }}>
      <label htmlFor={htmlFor} style={labelStyle}>{label}</label>
      <div>
        {children}
        {hint && (
          <div style={{ fontSize: 11, color: 'var(--text-faint)', marginTop: 4 }}>{hint}</div>
        )}
      </div>
    </div>
  )
}

/** Auth status badge color. */
function authBadgeColor(status: ChannelAuthStatus): string {
  switch (status) {
    case 'configured': return 'var(--text-faint)'
    case 'missing-credential': return 'var(--needs-input)'
    case 'vault-locked': return 'var(--needs-input)'
  }
}

/** Validate channel id: non-empty, no leading dash, only [A-Za-z0-9_-]. */
function isValidChannelId(id: string): boolean {
  if (id.length === 0) return false
  if (id.startsWith('-')) return false
  return /^[A-Za-z0-9_-]+$/.test(id)
}

/** Parse allow_from text: split on comma, trim, filter empty. */
function parseAllowFrom(value: string): string[] {
  return value.split(',').map((s) => s.trim()).filter(Boolean)
}

// ── Component ───────────────────────────────────────────────────────────

/** The Channels CRUD view. Lists every configured channel on the left; the
 *  right pane is an editor (create or edit). Creating POSTs /api/channels;
 *  editing PUTs /api/channels/:id; the trash button DELETEs.
 *
 *  After any successful mutation, a "restart needed" notice is shown —
 *  channel configuration changes require a `seal serve` restart to take
 *  effect on running listeners.
 *
 *  SECURITY: the token field is write-only (type="password"), never
 *  pre-filled. The stored token is never retrieved or displayed. */
export function ChannelsView() {
  const { channels, loaded, error, refresh } = useChannels()

  const [editing, setEditing] = useState<string | null>(null)
  const [creating, setCreating] = useState(false)
  // The form state — uses snake_case keys for the input wire on submit.
  const [formId, setFormId] = useState('')
  const [formKind, setFormKind] = useState('signal')
  const [formLabel, setFormLabel] = useState('')
  const [formAccount, setFormAccount] = useState('')
  const [formToken, setFormToken] = useState('')
  const [formChunkLimit, setFormChunkLimit] = useState('')
  const [formAllowFrom, setFormAllowFrom] = useState('')
  const [submitting, setSubmitting] = useState(false)
  const [formError, setFormError] = useState<string | null>(null)
  const [confirmingDelete, setConfirmingDelete] = useState<string | null>(null)
  const [restartNeeded, setRestartNeeded] = useState(false)

  // Ref holding the latest `channels` list so the seed effect can read it
  // without re-running on every refresh tick.
  const channelsRef = useRef(channels)
  channelsRef.current = channels

  // When the user picks a channel to edit (or starts creating), seed the form.
  useEffect(() => {
    if (creating) {
      setFormId('')
      setFormKind('signal')
      setFormLabel('')
      setFormAccount('')
      setFormToken('')
      setFormChunkLimit('')
      setFormAllowFrom('')
      setFormError(null)
      return
    }
    if (editing) {
      const c = channelsRef.current.find((ch) => ch.id === editing)
      if (c) {
        setFormKind(c.kind)
        setFormLabel(c.label ?? '')
        setFormAccount(c.account ?? '')
        setFormToken('')
        setFormChunkLimit(c.textChunkLimit != null ? String(c.textChunkLimit) : '')
        setFormAllowFrom(c.allowFrom ? c.allowFrom.join(', ') : '')
        setFormError(null)
      }
    }
  }, [editing, creating])

  const selected = useMemo(
    () => (editing ? channels.find((ch) => ch.id === editing) ?? null : null),
    [editing, channels],
  )

  const handleSubmit = async () => {
    setSubmitting(true)
    setFormError(null)
    const trimmedId = formId.trim()
    if (creating) {
      const payload: ChannelInput = {
        id: trimmedId,
        kind: formKind,
        label: formLabel.trim() || undefined,
        account: formKind === 'signal' && formAccount.trim() ? formAccount.trim() : undefined,
        token: formKind === 'telegram' && formToken.trim() ? formToken.trim() : undefined,
        text_chunk_limit: formChunkLimit.trim() ? Number(formChunkLimit.trim()) : undefined,
        allow_from: formAllowFrom.trim() ? parseAllowFrom(formAllowFrom) : undefined,
      }
      const res = await createChannel(payload)
      setSubmitting(false)
      if (res.ok) {
        refresh()
        setCreating(false)
        setEditing(res.channel.id)
        setRestartNeeded(true)
      } else {
        setFormError(res.error)
      }
    } else if (editing) {
      const payload: ChannelUpdateInput = {
        label: formLabel.trim() || undefined,
        account: formKind === 'signal' && formAccount.trim() ? formAccount.trim() : undefined,
        token: formKind === 'telegram' && formToken.trim() ? formToken.trim() : undefined,
        text_chunk_limit: formChunkLimit.trim() ? Number(formChunkLimit.trim()) : undefined,
        allow_from: formAllowFrom.trim() ? parseAllowFrom(formAllowFrom) : undefined,
      }
      const res = await updateChannel(editing, payload)
      setSubmitting(false)
      if (res.ok) {
        refresh()
        setEditing(res.channel.id)
        setRestartNeeded(true)
      } else {
        setFormError(res.error)
      }
    }
  }

  const handleDelete = async (id: string) => {
    const ok = await deleteChannel(id)
    if (ok) {
      if (editing === id) setEditing(null)
      if (confirmingDelete === id) setConfirmingDelete(null)
      refresh()
      setRestartNeeded(true)
    }
  }

  const handleNew = () => {
    setEditing(null)
    setCreating(true)
  }

  const handleCancel = () => {
    setCreating(false)
    setEditing(null)
    setFormError(null)
  }

  const handleSelectChannel = (id: string) => {
    if (confirmingDelete === id) setConfirmingDelete(null)
    setCreating(false)
    setEditing(id)
    // Clear restart notice on navigation (selecting a different channel).
    setRestartNeeded(false)
  }

  const isSignal = formKind === 'signal'
  const isTelegram = formKind === 'telegram'

  // Save is disabled when creating with an invalid id, or while submitting.
  const saveDisabled = submitting || (creating && !isValidChannelId(formId.trim()))

  // ── Render ──────────────────────────────────────────────────────────
  return (
    <div className="flex flex-1 min-h-0" style={{ background: 'var(--bg-base)' }}>
      {/* List pane */}
      <div
        className="shrink-0 flex flex-col"
        style={{
          width: 280,
          background: 'var(--bg-surface)',
          borderRight: '1px solid var(--border)',
        }}
      >
        <div
          className="flex items-center justify-between px-3 py-2"
          style={{ borderBottom: '1px solid var(--border)' }}
        >
          <span
            className="text-xs font-semibold uppercase"
            style={{ color: 'var(--text-muted)', letterSpacing: '0.08em' }}
          >
            Channels ({channels.length})
          </span>
          <button
            type="button"
            className="btn btn-ghost flex items-center justify-center"
            style={{ width: 22, height: 22, padding: 0, fontSize: 14, lineHeight: 1 }}
            onClick={handleNew}
            aria-label="New channel"
            title="New channel"
            data-testid="channel-new-btn"
          >
            +
          </button>
        </div>
        <div className="flex-1 overflow-y-auto sidebar-scroll">
          {!loaded && (
            <div className="px-3 py-2 text-xs" style={{ color: 'var(--text-faint)' }}>
              Loading…
            </div>
          )}
          {loaded && error && (
            <div className="px-3 py-2 text-xs" style={{ color: 'var(--needs-input)' }}>
              Failed to load — the backend may be unreachable.
            </div>
          )}
          {loaded && !error && channels.length === 0 && (
            <div className="px-3 py-2 text-xs" style={{ color: 'var(--text-faint)' }}>
              No channels configured.
            </div>
          )}
          {channels.map((c) => {
            const isActive = (creating ? false : editing === c.id) && !confirmingDelete
            return (
              <div
                key={c.id}
                data-testid={`channel-row-${c.id}`}
                className={`agent-row px-3 py-2 cursor-pointer${isActive ? ' selected' : ''}`}
                onClick={() => handleSelectChannel(c.id)}
              >
                <div className="flex items-center gap-2">
                  <span
                    className="text-sm truncate mr-auto"
                    style={{ color: 'var(--text-primary)', letterSpacing: 'var(--tracking-tight)' }}
                  >
                    {c.label || c.id}
                  </span>
                  <span
                    className="pill"
                    style={{
                      background: 'var(--bg-elevated)',
                      color: 'var(--text-faint)',
                      padding: '0 0.4em',
                      fontSize: '0.7em',
                    }}
                  >
                    {KIND_LABELS[c.kind] ?? c.kind}
                  </span>
                </div>
                <div
                  className="text-xs mt-0.5 truncate"
                  style={{ color: authBadgeColor(c.authStatus) }}
                >
                  {AUTH_STATUS_LABELS[c.authStatus]}
                </div>
              </div>
            )
          })}
        </div>
      </div>

      {/* Editor / detail pane */}
      <div className="flex-1 overflow-y-auto" style={{ padding: '24px 32px' }}>
        {restartNeeded && (
          <div
            data-testid="channel-restart-notice"
            className="flex items-center gap-2"
            style={{
              background: 'var(--bg-elevated)',
              color: 'var(--text-muted)',
              border: '1px solid var(--border)',
              borderRadius: 'var(--radius-sm)',
              padding: '8px 12px',
              marginBottom: 16,
              fontSize: 13,
            }}
          >
            <span>⚠</span>
            <span>Channel configuration saved. Restart <code>seal serve</code> for the change to take effect on running listeners.</span>
          </div>
        )}
        {error && !loaded && (
          <div
            data-testid="channels-load-error"
            style={{ fontSize: 12, color: 'var(--needs-input)', marginBottom: 12 }}
          >
            Failed to load channels — the backend may be unreachable.
          </div>
        )}
        {!creating && !selected && (
          <div
            className="flex flex-col items-center justify-center"
            style={{ height: '100%', color: 'var(--text-faint)', gap: 8 }}
          >
            <div className="text-sm">Select a channel to edit, or click + to add one.</div>
          </div>
        )}
        {(creating || selected) && (
          <div
            className="flex flex-col gap-4"
            style={{ maxWidth: 640, margin: '0 auto' }}
            data-testid={creating ? 'channel-form-new' : `channel-form-${editing ?? ''}`}
          >
            <div className="flex items-center gap-2">
              <span className="text-lg font-semibold" style={{ color: 'var(--text-primary)' }}>
                {creating ? 'New channel' : ((selected?.label || selected?.id) ?? 'Channel')}
              </span>
              {selected && (
                <span
                  className="pill"
                  style={{
                    background: 'var(--bg-elevated)',
                    color: 'var(--text-faint)',
                    fontSize: 11,
                    padding: '0 6px',
                  }}
                >
                  {KIND_LABELS[selected.kind] ?? selected.kind}
                </span>
              )}
              {selected && (
                <span
                  className="pill"
                  style={{
                    background: 'var(--bg-elevated)',
                    color: authBadgeColor(selected.authStatus),
                    fontSize: 11,
                    padding: '0 6px',
                  }}
                >
                  {AUTH_STATUS_LABELS[selected.authStatus]}
                </span>
              )}
            </div>

            {creating && (
              <Row label="Kind" htmlFor="channel-kind" hint="Select the channel type. Cannot be changed after creation.">
                <select
                  id="channel-kind"
                  data-testid="channel-kind-select"
                  value={formKind}
                  onChange={(e) => setFormKind(e.target.value)}
                  className="composer-select"
                  style={inputStyle}
                >
                  <option value="signal">Signal</option>
                  <option value="telegram">Telegram</option>
                </select>
              </Row>
            )}

            {creating && (
              <Row label="Id" htmlFor="channel-id" hint="The unique channel id. Letters, numbers, hyphens, and underscores only — no leading dash.">
                <input
                  id="channel-id"
                  data-testid="channel-id-input"
                  type="text"
                  value={formId}
                  onChange={(e) => setFormId(e.target.value)}
                  style={inputStyle}
                  placeholder="e.g. work-signal"
                  autoComplete="off"
                />
              </Row>
            )}

            <Row label="Label" htmlFor="channel-label" hint="Human-readable name (optional).">
              <input
                id="channel-label"
                data-testid="channel-label-input"
                type="text"
                value={formLabel}
                onChange={(e) => setFormLabel(e.target.value)}
                style={inputStyle}
                placeholder="(optional)"
                autoComplete="off"
              />
            </Row>

            {isSignal && (
              <Row label="Account" htmlFor="channel-account" hint="Signal phone number or UUID.">
                <input
                  id="channel-account"
                  data-testid="channel-account-input"
                  type="text"
                  value={formAccount}
                  onChange={(e) => setFormAccount(e.target.value)}
                  style={inputStyle}
                  placeholder="e.g. +15555550123"
                  autoComplete="off"
                />
              </Row>
            )}

            {isTelegram && (
              <Row label="Token" htmlFor="channel-token" hint="Telegram bot token. Stored in the vault — never displayed. Paste a new token to rotate.">
                <input
                  id="channel-token"
                  data-testid="channel-token-input"
                  type="password"
                  value={formToken}
                  onChange={(e) => setFormToken(e.target.value)}
                  style={inputStyle}
                  placeholder="Enter bot token"
                  autoComplete="off"
                />
              </Row>
            )}

            <Row label="Text chunk limit" htmlFor="channel-chunk" hint="Max characters per message chunk (optional).">
              <input
                id="channel-chunk"
                data-testid="channel-chunk-input"
                type="number"
                value={formChunkLimit}
                onChange={(e) => setFormChunkLimit(e.target.value)}
                style={inputStyle}
                placeholder="(optional)"
                autoComplete="off"
              />
            </Row>

            <Row label="Allow from" htmlFor="channel-allow" hint="Comma-separated list of allowed sender ids. Leave blank to allow all.">
              <input
                id="channel-allow"
                data-testid="channel-allow-input"
                type="text"
                value={formAllowFrom}
                onChange={(e) => setFormAllowFrom(e.target.value)}
                style={inputStyle}
                placeholder="e.g. +15555550123, 123456789"
                autoComplete="off"
              />
            </Row>

            {formError && (
              <div
                data-testid="channel-form-error"
                style={{ fontSize: 12, color: 'var(--needs-input)' }}
              >
                {formError}
              </div>
            )}

            <div
              className="flex flex-col gap-2"
              style={{ borderTop: '1px solid var(--border)', paddingTop: 16 }}
            >
              <div className="flex gap-2">
                <button
                  type="button"
                  className="btn btn-primary px-3 py-2 rounded-lg text-sm font-medium"
                  onClick={handleSubmit}
                  disabled={saveDisabled}
                  aria-label={creating ? 'Create channel' : 'Save channel'}
                  data-testid="channel-save"
                >
                  {creating ? 'Create' : 'Save'}
                </button>
                <button
                  type="button"
                  className="btn btn-ghost px-3 py-2 rounded-lg text-sm font-medium"
                  onClick={handleCancel}
                >
                  Cancel
                </button>
                {!creating && selected && confirmingDelete !== selected.id && (
                  <button
                    type="button"
                    className="btn btn-danger-ghost px-3 py-2 rounded-lg text-sm font-medium"
                    style={{ marginLeft: 'auto' }}
                    onClick={() => setConfirmingDelete(selected.id)}
                    aria-label="Delete channel"
                    data-testid="channel-delete"
                  >
                    Delete
                  </button>
                )}
              </div>
              {!creating && selected && confirmingDelete === selected.id && (
                <div className="flex flex-col gap-2" data-testid="channel-delete-confirm">
                  <span className="text-sm" style={{ color: 'var(--needs-input)' }}>
                    Delete channel <strong>{selected.id}</strong>? This removes the vault credential and cannot be undone.
                  </span>
                  <div className="flex gap-2">
                    <button
                      type="button"
                      className="btn btn-danger-ghost px-3 py-2 rounded-lg text-sm font-medium"
                      style={{ background: 'var(--needs-input)', color: 'var(--text-primary)' }}
                      onClick={() => void handleDelete(selected.id)}
                      aria-label="Confirm delete"
                      data-testid="channel-delete-confirm-btn"
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
  )
}
