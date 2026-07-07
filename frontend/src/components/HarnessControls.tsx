import { useState } from 'react'
import type { SessionInfo, TabInfo, TabStatus } from '../types'
import { sessionDisplayTitle, tabDisplayLabel } from '../types'
import { ActivityDot } from './StatusDot'

const statusLabel: Record<TabStatus, string> = {
  running: 'Running',
  idle: 'Idle',
  exited: 'Exited',
  orphaned: 'Orphaned',
}

/** Map a TabStatus to the HarnessActivity vocabulary ActivityDot accepts.
 *  `running` maps to `thinking` (active glyph), `idle` to `idle`, and the
 *  dead states (`exited`/`orphaned`) to `stopped`. */
const statusActivity: Record<TabStatus, 'thinking' | 'idle' | 'needs-input' | 'stopped'> = {
  running: 'thinking',
  idle: 'idle',
  exited: 'stopped',
  orphaned: 'stopped',
}

function Field({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div className="flex flex-col gap-1">
      <span
        className="text-xs font-semibold uppercase"
        style={{ color: 'var(--text-muted)', letterSpacing: '0.08em' }}
      >
        {label}
      </span>
      <div className="text-sm" style={{ color: 'var(--text-primary)' }}>
        {children}
      </div>
    </div>
  )
}

/** The right-pane view shown when a harness tab is selected. A harness has
 *  no conversation transcript of its own, so instead of a chat we surface its
 *  status, the session it is associated with, and Release / Destroy controls.
 *
 *  Release stops Seal from managing an ADOPTED harness without killing the
 *  underlying tmux window. Destroy terminates the harness's processes and
 *  archives its session; for an ADOPTED harness the backend fail-closes
 *  unless `confirm_adopted: true` is sent, so a two-step confirmation names
 *  the consequence before `onDestroy(index, true)` is called. */
export function HarnessControls({
  tab,
  session,
  onOpenSession,
  onRelease,
  onDestroy,
}: {
  tab: TabInfo
  session: SessionInfo | null
  /** Navigate to the harness's backing session. Called with the session id
   *  when the link is clicked. */
  onOpenSession?: (sessionId: string) => void
  /** Release an ADOPTED harness: Seal stops managing it (unmarks the tmux
   *  window, deregisters) but leaves the window + processes running. Only
   *  offered for adopted harnesses (the backend rejects release of a spawned
   *  one). */
  onRelease?: (index: number) => void
  onDestroy: (index: number, confirmAdopted: boolean) => void
}) {
  const [confirming, setConfirming] = useState(false)
  const associatedSessionId = tab.session_id
  const isAdopted = tab.origin === 'adopted'
  const status = statusLabel[tab.status] ?? tab.status
  const activity = statusActivity[tab.status] ?? 'idle'

  const handleDestroyClick = () => {
    if (isAdopted) {
      setConfirming(true)
    } else {
      onDestroy(tab.index, false)
    }
  }

  return (
    <div className="flex-1 overflow-y-auto" style={{ padding: '24px 32px' }}>
      <div className="flex flex-col gap-5" style={{ maxWidth: 560 }}>
        <div className="flex items-center gap-2">
          <span className="text-lg font-semibold" style={{ color: 'var(--text-primary)' }}>
            {tabDisplayLabel(tab, session)}
          </span>
          {tab.origin && (
            <span
              className="pill"
              style={{ background: 'var(--bg-elevated)', color: 'var(--text-faint)', fontSize: 11, padding: '0 6px' }}
            >
              {tab.origin}
            </span>
          )}
        </div>

        <Field label="Status">
          <span className="flex items-center gap-1">
            <span data-testid={`status-${tab.status}`}>
              <ActivityDot activity={activity} />
            </span>
            {status}
            {tab.stale && <span style={{ color: 'var(--text-faint)' }}> (stale)</span>}
          </span>
        </Field>

        <Field label="Associated session">
          {associatedSessionId ? (
            <button
              type="button"
              onClick={() => onOpenSession?.(associatedSessionId)}
              className="flex flex-col items-start"
              style={{
                background: 'none',
                border: 'none',
                padding: 0,
                cursor: 'pointer',
                textAlign: 'left',
              }}
              title="Open this session"
            >
              {session && (
                <span style={{ color: 'var(--accent)', textDecoration: 'underline' }}>
                  {sessionDisplayTitle(session)}
                </span>
              )}
              <span
                className="text-xs"
                style={{ color: 'var(--accent)', textDecoration: 'underline' }}
              >
                {associatedSessionId}
              </span>
            </button>
          ) : (
            <span style={{ color: 'var(--text-faint)' }}>No session associated yet.</span>
          )}
        </Field>

        {session && (
          <Field label="Agent">
            <span style={{ color: 'var(--text-primary)' }}>
              {session.agent ?? '—'}
            </span>
          </Field>
        )}

        {session && (
          <Field label="Model">
            <span style={{ color: 'var(--text-primary)' }}>
              {session.model || '—'}
            </span>
          </Field>
        )}

        {tab.attachCommand && (
          <Field label="Attach command">
            <code className="text-xs" style={{ color: 'var(--text-muted)' }}>
              {tab.attachCommand}
            </code>
          </Field>
        )}

        <div className="flex flex-col gap-2" style={{ borderTop: '1px solid var(--border)', paddingTop: 16 }}>
          {isAdopted && (
            <>
              <button
                className="btn btn-ghost px-3 py-2 rounded-lg text-sm font-medium"
                style={{ alignSelf: 'flex-start' }}
                onClick={() => onRelease?.(tab.index)}
              >
                Release (stop managing)
              </button>
              <span className="text-xs" style={{ color: 'var(--text-faint)' }}>
                Seal stops managing this harness and unmarks its tmux window, retitling it
                “… (released)” so you can see Seal has detached — but leaves the window and its
                processes intact for you to keep using or clean up manually. The session transcript is kept.
              </span>
            </>
          )}
          {!confirming ? (
            <button
              className="btn px-3 py-2 rounded-lg text-sm font-medium"
              style={{
                alignSelf: 'flex-start',
                background: 'var(--needs-input-bg, var(--bg-elevated))',
                color: 'var(--needs-input)',
                border: '1px solid var(--needs-input)',
              }}
              onClick={handleDestroyClick}
            >
              Destroy harness
            </button>
          ) : (
            <div className="flex flex-col gap-2">
              <span className="text-sm" style={{ color: 'var(--needs-input)' }}>
                This harness was adopted — Seal did not create it. Destroying it will{' '}
                <strong>kill the underlying tmux window and its processes</strong>, not just stop
                managing it. This cannot be undone.
              </span>
              <div className="flex gap-2">
                <button
                  className="btn px-3 py-2 rounded-lg text-sm font-medium"
                  style={{ background: 'var(--needs-input)', color: 'var(--text-primary)' }}
                  onClick={() => {
                    setConfirming(false)
                    onDestroy(tab.index, true)
                  }}
                >
                  Confirm destroy
                </button>
                <button
                  className="btn btn-ghost px-3 py-2 rounded-lg text-sm font-medium"
                  onClick={() => setConfirming(false)}
                >
                  Cancel
                </button>
              </div>
            </div>
          )}
          <span className="text-xs" style={{ color: 'var(--text-faint)' }}>
            Terminates the harness's processes and archives its session
            (the transcript is kept on disk).
          </span>
        </div>
      </div>
    </div>
  )
}