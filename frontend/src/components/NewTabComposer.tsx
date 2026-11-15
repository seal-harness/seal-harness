import { useEffect, useState } from 'react'
import {
  type HarnessFlavour,
  type NewTabKind,
  type NewTabSpec,
} from '../hooks/useNewTabSpec'
import { adoptWindow, createTab, setupRepo, type NewTabResponse } from '../hooks/useApi'
import { CustomModelCombobox, ProviderSelect, inputStyle } from './ProviderModelFields'

// Human labels for each tab kind. 'harness' is the spawn-a-new-harness flow;
// 'attach' is the adopt-a-running-harness flow.
const KIND_LABELS: Record<NewTabKind, string> = {
  provider: 'AI Provider',
  harness: 'New Harness',
  attach: 'Existing Harness',
}

// ── Props ─────────────────────────────────────────────────────────────

interface NewTabComposerProps {
  spec: NewTabSpec
  /** Called after a successful createTab (provider/harness) or adoptWindow
   *  (attach). The response is passed back so the parent can navigate to
   *  the newly-created tab/session (null for the attach kind, which has no
   *  createTab response). */
  onSubmit: (res: NewTabResponse | null) => void
  onCancel: () => void
  /** When branching, pre-fills the `branch_from` field and locks the kind to
   *  provider (branching creates a provider session seeded from an existing
   *  transcript entry). Undefined for the plain new-tab flow. */
  branchFrom?: string
}

// ── Component ─────────────────────────────────────────────────────────

export function NewTabComposer({ spec, onSubmit, onCancel, branchFrom }: NewTabComposerProps) {
  // Only configured providers are selectable. Unconfigured types stay hidden:
  // they belong in the Providers screen, not in a "start a new tab" picker.
  // `configured` absent => configured (back-compat with older test mocks).
  const selectableProviders = spec.configuredProviders.filter((p) => p.configured !== false)
  const lockedToProvider = branchFrom !== undefined
  const [repoWarning, setRepoWarning] = useState<string | null>(null)
  const [submitting, setSubmitting] = useState(false)

  // Lock the kind to provider whenever a branchFrom is supplied. The hook's
  // own state is the source of truth; we just force-set it here whenever the
  // prop flips (and the kind pills below are disabled so the user can't leave).
  useEffect(() => {
    if (lockedToProvider && spec.kind !== 'provider') {
      spec.setKind('provider')
    }
  }, [lockedToProvider, spec.kind, spec.setKind])

  const handleSubmit = async () => {
    if (spec.validationError) return
    setSubmitting(true)
    setRepoWarning(null)
    if (spec.kind === 'attach') {
      const res = await adoptWindow(spec.attachSession, spec.attachWindow, spec.attachWindowIndex)
      if (res.ok) {
        spec.persistOnSubmit()
        onSubmit(null)
      } else {
        setSubmitting(false)
      }
      return
    }
    const body = spec.buildBody()
    if (branchFrom) body.branch_from = branchFrom
    const res = await createTab(body)
    if (res) {
      // If the user entered a repo URL and the new tab has a session id
      // (provider kind), dispatch SETUP_REPO into the session's
      // transcript (audited — visible in the chat, not a silent side
      // channel). A clone failure does NOT block the tab; the error is
      // recorded in the transcript. The repo is recorded to history via
      // persistOnSubmit regardless of clone success.
      const repoUrl = spec.repo.trim()
      if (repoUrl && res.session_id) {
        const result = await setupRepo(res.session_id, repoUrl, spec.repoBranch.trim() || undefined)
        if (!result || !result.ok) {
          const reason = result?.error ?? 'network error'
          setRepoWarning(`Could not set up repo "${repoUrl}": ${reason}. See the SETUP_REPO entry in the transcript for details; try https:// instead of git@.`)
        }
      }
      spec.persistOnSubmit()
      onSubmit(res)
    } else {
      // createTab failed — re-enable the form so the user can retry.
      setSubmitting(false)
    }
  }

  // While the server round-trip is in flight, replace the entire form body
  // with a spinner so the user gets immediate visual feedback that their
  // click was registered. The header stays for context.
  if (submitting) {
    return (
      <div style={{
        display: 'flex',
        flexDirection: 'column',
        gap: 16,
        maxWidth: 640,
        margin: '0 auto',
        padding: '24px 0',
      }}>
        <div style={{ fontSize: 16, fontWeight: 600, color: 'var(--text-primary)' }}>
          {branchFrom ? 'Branch from here' : 'Start a new tab'}
        </div>
        <div style={{
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'center',
          padding: '48px 0',
        }}>
          <span className="composer-spinner" role="status" aria-label="Creating session" />
        </div>
      </div>
    )
  }

  return (
    <div style={{
      display: 'flex',
      flexDirection: 'column',
      gap: 16,
      maxWidth: 640,
      margin: '0 auto',
      padding: '24px 0',
    }}>
      <div style={{ fontSize: 16, fontWeight: 600, color: 'var(--text-primary)' }}>
        {branchFrom ? 'Branch from here' : 'Start a new tab'}
      </div>

      {/* Kind pills */}
      <div role="radiogroup" aria-label="Tab kind" style={{ display: 'flex', gap: 6 }}>
        {(['provider', 'harness', 'attach'] as NewTabKind[]).map((k) => {
          const disabled = lockedToProvider && k !== 'provider'
          return (
            <button
              key={k}
              type="button"
              role="radio"
              aria-checked={spec.kind === k}
              onClick={() => spec.setKind(k)}
              disabled={disabled}
              className={spec.kind === k ? 'btn btn-primary' : 'btn btn-ghost'}
              style={{
                padding: '6px 12px',
                fontSize: 13,
                borderRadius: 'var(--radius-sm)',
                border: '1px solid var(--border)',
                opacity: disabled ? 0.4 : 1,
                cursor: disabled ? 'not-allowed' : 'pointer',
              }}
            >
              {KIND_LABELS[k]}
            </button>
          )
        })}
      </div>

      {/* Provider kind config */}
      {spec.kind === 'provider' && (
        <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
          <Row label="Provider" htmlFor="provider-select">
            <ProviderSelect
              id="provider-select"
              value={spec.provider}
              onChange={spec.setProvider}
              providers={selectableProviders}
              loading={!spec.providersLoaded}
              showNoProvidersNotice
            />
          </Row>

          <Row label="Model" htmlFor="provider-model">
            <CustomModelCombobox
              id="provider-model"
              value={spec.model}
              onChange={spec.setModel}
              options={spec.modelOptions}
              placeholder="model id (pick a suggestion or type your own)"
              testId="provider-model-list"
            />
          </Row>

          <Row label="Set up repo" htmlFor="provider-repo">
            <CustomModelCombobox
              id="provider-repo"
              value={spec.repo}
              onChange={spec.setRepo}
              options={spec.repoOptions}
              placeholder="git URL (optional — cloned into the session before turn one)"
              testId="provider-repo-list"
            />
          </Row>

          {/* Only meaningful alongside a repo: a branch with nothing to
              clone would silently do nothing. */}
          {spec.repo.trim() !== '' && (
            <Row label="Repo Branch" htmlFor="provider-repo-branch">
              <input
                id="provider-repo-branch"
                type="text"
                value={spec.repoBranch}
                onChange={(e) => spec.setRepoBranch(e.target.value)}
                style={inputStyle}
                placeholder="branch or tag (optional — default branch)"
              />
            </Row>
          )}

          {branchFrom && (
            <Row label="Branch From" htmlFor="provider-branch-from">
              <input
                id="provider-branch-from"
                type="text"
                value={branchFrom}
                readOnly
                style={{ ...inputStyle, opacity: 0.6, cursor: 'not-allowed' }}
              />
            </Row>
          )}
        </div>
      )}

      {/* Harness kind config */}
      {spec.kind === 'harness' && (
        <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
          <Row label="Flavour" htmlFor="harness-flavour">
            <select
              id="harness-flavour"
              value={spec.flavour}
              onChange={(e) => spec.setFlavour(e.target.value as HarnessFlavour)}
              className="composer-select"
              style={inputStyle}
            >
              <option value="claude-code">Claude Code</option>
              <option value="codex">Codex</option>
              <option value="opencode">OpenCode</option>
              <option value="hermes">Hermes</option>
              <option value="custom">Custom</option>
            </select>
          </Row>

          {spec.flavour === 'custom' && (
            <Row label="Binary Name" htmlFor="harness-binary">
              <input
                id="harness-binary"
                type="text"
                value={spec.customBinary}
                onChange={(e) => spec.setCustomBinary(e.target.value)}
                style={inputStyle}
                placeholder="e.g. my-ai-tool"
              />
            </Row>
          )}
        </div>
      )}

      {/* Existing Harness (attach / adoption) config */}
      {spec.kind === 'attach' && <ExistingHarnessSection spec={spec} />}

      {/* Inline validation hint. Helps the user understand why the
          submit button is disabled (and what to fix). */}
      {spec.validationError && (
        <div
          data-testid="composer-validation-error"
          style={{ fontSize: 12, color: 'var(--needs-input)' }}
        >
          {spec.validationError}
        </div>
      )}

      {repoWarning && (
        <div
          data-testid="composer-repo-warning"
          style={{ fontSize: 12, color: 'var(--needs-input)' }}
        >
          {repoWarning}
        </div>
      )}

      <div style={{ display: 'flex', gap: 8, justifyContent: 'flex-end' }}>
        <button
          type="button"
          className="btn btn-ghost px-3 py-2 rounded-lg text-sm font-medium"
          onClick={onCancel}
        >
          Cancel
        </button>
        <button
          type="button"
          className="btn btn-primary px-3 py-2 rounded-lg text-sm font-medium"
          onClick={handleSubmit}
          disabled={spec.validationError !== null}
          aria-label="Submit new tab"
        >
          {branchFrom ? 'Branch' : 'Start'}
        </button>
      </div>
    </div>
  )
}

// ── Existing Harness (attach) section ─────────────────────────────────

/** Encode a detected window as a single <option> value so a dropdown selection
 *  round-trips the session, the window INDEX, and the window name. The index is
 *  included because window names repeat within a session, so name alone can't
 *  identify the picked window — two same-named windows would collide to one
 *  value. The NUL separator can't appear in a tmux name. */
const ATTACH_SEP = ' '
function encodeWindow(w: { session: string; windowIndex: number; windowName: string }): string {
  return `${w.session}${ATTACH_SEP}${w.windowIndex}${ATTACH_SEP}${w.windowName}`
}

function ExistingHarnessSection({ spec }: { spec: NewTabSpec }) {
  const windows = spec.discoverableWindows
  const hasWindows = windows.length > 0
  // Fall back to manual entry automatically when there's nothing to pick
  // (empty scan or a scan error), or when the user opted in explicitly.
  const showManual = spec.attachManual || !hasWindows
  // Match the current selection by session + INDEX (the unique key) so a
  // picked window resolves even when another window shares its name.
  const selectedValue =
    spec.attachWindowIndex !== null &&
    windows.some((w) => w.session === spec.attachSession && w.windowIndex === spec.attachWindowIndex)
      ? encodeWindow({ session: spec.attachSession, windowIndex: spec.attachWindowIndex, windowName: spec.attachWindow })
      : ''

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
      {/* Consent note: submitting the form IS the consent. Name the trust
          consequence explicitly so the user understands what attaching does. */}
      <div
        data-testid="attach-consent-note"
        style={{ fontSize: 12, color: 'var(--text-muted)', lineHeight: 1.4 }}
      >
        Seal will manage this window and capture its output from now on.
      </div>

      {spec.discoveryError && (
        <div style={{ fontSize: 12, color: 'var(--needs-input)' }}>
          Could not scan for running sessions — enter one manually below.
        </div>
      )}

      {hasWindows && !spec.attachManual && (
        <Row label="Detected Session" htmlFor="attach-detected">
          <select
            id="attach-detected"
            value={selectedValue}
            className="composer-select"
            onChange={(e) => {
              if (e.target.value === '') {
                spec.setAttachSession('')
                spec.setAttachWindow('')
                spec.setAttachWindowIndex(null)
                return
              }
              const parts = e.target.value.split(ATTACH_SEP)
              const session = parts[0] ?? ''
              const windowIndex = parts[1] ?? undefined
              const windowName = parts[2] ?? ''
              spec.setAttachSession(session)
              spec.setAttachWindow(windowName)
              spec.setAttachWindowIndex(windowIndex === undefined ? null : Number(windowIndex))
            }}
            style={inputStyle}
          >
            <option value="">(pick a detected session)</option>
            {windows.map((w) => (
              <option key={encodeWindow(w)} value={encodeWindow(w)}>
                {w.session}:{w.windowIndex} {w.windowName}
              </option>
            ))}
          </select>
        </Row>
      )}

      {!hasWindows && !spec.discoveryError && (
        <div style={{ fontSize: 12, color: 'var(--text-muted)' }}>
          No running sessions detected — enter one manually below.
        </div>
      )}

      {hasWindows && (
        <label style={{ fontSize: 12, color: 'var(--text-muted)', display: 'flex', gap: 6, alignItems: 'center' }}>
          <input
            type="checkbox"
            aria-label="Enter manually"
            checked={spec.attachManual}
            onChange={(e) => spec.setAttachManual(e.target.checked)}
          />
          Enter manually
        </label>
      )}

      {showManual && (
        <>
          <Row label="Session" htmlFor="attach-session">
            <input
              id="attach-session"
              type="text"
              value={spec.attachSession}
              onChange={(e) => {
                spec.setAttachSession(e.target.value)
                // Manual edit invalidates any picked index — match by name.
                spec.setAttachWindowIndex(null)
              }}
              style={inputStyle}
              placeholder="tmux session name"
            />
          </Row>
          <Row label="Window" htmlFor="attach-window">
            <input
              id="attach-window"
              type="text"
              value={spec.attachWindow}
              onChange={(e) => {
                spec.setAttachWindow(e.target.value)
                // Manual edit invalidates any picked index — match by name.
                spec.setAttachWindowIndex(null)
              }}
              style={inputStyle}
              placeholder="tmux window name"
            />
          </Row>
        </>
      )}
    </div>
  )
}

// ── Small helpers ─────────────────────────────────────────────────────

const labelStyle: React.CSSProperties = {
  fontSize: 12,
  fontWeight: 500,
  color: 'var(--text-muted)',
}

function Row({
  label, htmlFor, children,
}: { label: string; htmlFor: string; children: React.ReactNode }) {
  return (
    <div style={{ display: 'grid', gridTemplateColumns: '140px 1fr', alignItems: 'center', gap: 12 }}>
      <label htmlFor={htmlFor} style={labelStyle}>{label}</label>
      <div>{children}</div>
    </div>
  )
}
