import { useEffect, useRef, useState } from 'react'
import { createPortal } from 'react-dom'
import {
  CUSTOM_MODEL_VALUE,
  type HarnessFlavour,
  type NewTabKind,
  type NewTabSpec,
} from '../hooks/useNewTabSpec'
import { adoptWindow, createTab, type NewTabResponse } from '../hooks/useApi'

const PROVIDER_LABELS: Record<string, string> = {
  anthropic: 'Anthropic',
  openai: 'OpenAI',
  openrouter: 'OpenRouter',
  ollama: 'Ollama',
}

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
  const safeAgents = Array.isArray(spec.agents) ? spec.agents : []
  const noProviders = spec.providersLoaded && spec.configuredProviders.length === 0
  const lockedToProvider = branchFrom !== undefined

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
    if (spec.kind === 'attach') {
      const res = await adoptWindow(spec.attachSession, spec.attachWindow, spec.attachWindowIndex)
      if (res.ok) {
        spec.persistOnSubmit()
        onSubmit(null)
      }
      return
    }
    const body = spec.buildBody()
    if (branchFrom) body.branch_from = branchFrom
    const res = await createTab(body)
    if (res) {
      spec.persistOnSubmit()
      onSubmit(res)
    }
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
            <select
              id="provider-select"
              value={spec.provider}
              onChange={(e) => spec.setProvider(e.target.value)}
              disabled={!spec.providersLoaded || noProviders}
              className="composer-select"
              style={inputStyle}
            >
              {!spec.providersLoaded && <option value="">Loading…</option>}
              {noProviders && (
                <option value="" disabled>
                  (no providers configured — set an API key or start Ollama)
                </option>
              )}
              {spec.configuredProviders.map((p) => (
                <option key={p.name} value={p.name}>
                  {PROVIDER_LABELS[p.name] ?? p.name}{p.isDefault ? ' (default)' : ''}
                </option>
              ))}
            </select>
          </Row>

          <Row label="Model" htmlFor="provider-model">
            <select
              id="provider-model"
              value={spec.useCustomModel ? CUSTOM_MODEL_VALUE : spec.model}
              onChange={(e) => spec.handleModelSelectChange(e.target.value)}
              disabled={spec.modelsLoading}
              className="composer-select"
              style={inputStyle}
            >
              {spec.modelsLoading && <option value="">Loading…</option>}
              {!spec.modelsLoading && spec.models.length === 0 && (
                <option value="" disabled>(no models — choose Custom… and enter one)</option>
              )}
              {spec.models.map((m) => <option key={m.name} value={m.name}>{m.name}</option>)}
              <option value={CUSTOM_MODEL_VALUE}>Custom…</option>
            </select>
          </Row>

          {spec.useCustomModel && (
            <Row label="Custom Model" htmlFor="provider-model-custom">
              <CustomModelCombobox
                id="provider-model-custom"
                value={spec.model}
                onChange={spec.setModel}
                options={spec.customModels}
                placeholder="model id (e.g. claude-3-opus-20240229)"
              />
            </Row>
          )}

          <Row label="Agent" htmlFor="provider-agent">
            <select
              id="provider-agent"
              value={spec.agent}
              onChange={(e) => spec.handleAgentChange(e.target.value)}
              className="composer-select"
              style={inputStyle}
            >
              <option value="">(none)</option>
              {safeAgents.map((a) => (
                <option key={a.name} value={a.name}>
                  {a.name}{a.isDefault ? ' (default)' : ''}
                </option>
              ))}
            </select>
          </Row>

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

const inputStyle: React.CSSProperties = {
  fontSize: 14,
  padding: '6px 10px',
  // Use backgroundColor (not the background shorthand) so the composer-select /
  // composer-datalist classes can supply background-image (the chevron) — the
  // shorthand would reset background-image to none and clobber the chevron.
  backgroundColor: 'var(--bg-sunken)',
  border: '1px solid var(--border)',
  borderRadius: 'var(--radius-sm)',
  color: 'var(--text-primary)',
  outline: 'none',
  fontFamily: 'inherit',
  width: '100%',
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

// ── Custom Model combobox ──────────────────────────────────────────────
/* A self-contained combobox: a text input (free entry) plus a left-aligned
   popup of suggestions. Replaces the native <datalist>, whose popup position
   is browser-controlled (Chrome centers it under the input, ignoring CSS) and
   whose native ▾ indicator fights our shared chevron.

   The popup is rendered through a React Portal to document.body so it escapes
   the composer's clipping ancestor (`overflow-y-auto` on the composer wrapper
   in App.tsx) — without the portal the absolutely-positioned popup is clipped
   to the scroll container and never visible. Its position is derived from the
   input's getBoundingClientRect() so it stays left-aligned to the input box
   like the <select> dropdowns. The popup re-positions on scroll/resize while
   open so it tracks the input if the composer scrolls. The input carries the
   .composer-datalist class so it gets the same chevron and 10px left text
   inset as the other composer controls. */
function CustomModelCombobox({
  id, value, onChange, options, placeholder,
}: {
  id: string
  value: string
  onChange: (v: string) => void
  options: string[]
  placeholder?: string
}) {
  const [open, setOpen] = useState(false)
  const [active, setActive] = useState(-1)
  const [rect, setRect] = useState<DOMRect | null>(null)
  const wrapRef = useRef<HTMLDivElement>(null)
  const inputRef = useRef<HTMLInputElement>(null)

  const filtered = options.filter(
    (o) => o.toLowerCase().includes(value.toLowerCase()) && o !== value,
  )

  const measure = () => {
    if (inputRef.current) setRect(inputRef.current.getBoundingClientRect())
  }

  useEffect(() => {
    if (!open) return
    measure()
    const onScroll = () => measure()
    // Capture-phase listeners catch scroll on ancestors (e.g. the composer's
    // overflow-y-auto wrapper) before it repaints, so the popup tracks the
    // input instead of lagging behind.
    window.addEventListener('scroll', onScroll, true)
    window.addEventListener('resize', onScroll)
    const onDoc = (e: MouseEvent) => {
      if (wrapRef.current && !wrapRef.current.contains(e.target as Node)) setOpen(false)
    }
    document.addEventListener('mousedown', onDoc)
    return () => {
      window.removeEventListener('scroll', onScroll, true)
      window.removeEventListener('resize', onScroll)
      document.removeEventListener('mousedown', onDoc)
    }
  }, [open])

  const pick = (v: string) => { onChange(v); setOpen(false); setActive(-1) }

  const onKey = (e: React.KeyboardEvent<HTMLInputElement>) => {
    if (e.key === 'ArrowDown') {
      e.preventDefault()
      setOpen(true)
      setActive((a) => Math.min(a + 1, filtered.length - 1))
    } else if (e.key === 'ArrowUp') {
      e.preventDefault()
      setActive((a) => Math.max(a - 1, 0))
    } else if (e.key === 'Enter') {
      if (open && active >= 0 && active < filtered.length) {
        e.preventDefault()
        pick(filtered[active] as string)
      }
    } else if (e.key === 'Escape') {
      setOpen(false)
      setActive(-1)
    }
  }

  return (
    <div ref={wrapRef} style={{ position: 'relative', width: '100%' }}>
      <input
        ref={inputRef}
        id={id}
        type="text"
        value={value}
        onChange={(e) => { onChange(e.target.value); setOpen(true); setActive(-1) }}
        onFocus={() => { if (filtered.length > 0) setOpen(true) }}
        onKeyDown={onKey}
        className="composer-datalist"
        style={inputStyle}
        placeholder={placeholder}
        autoComplete="off"
      />
      {open && filtered.length > 0 && rect && createPortal(
        <div
          className="composer-combobox-popup"
          role="listbox"
          data-testid="provider-model-custom-list"
          style={{
            position: 'fixed',
            left: rect.left,
            top: rect.bottom + 2,
            width: rect.width,
            zIndex: 9999,
          }}
        >
          {filtered.map((o, i) => (
            <div
              key={o}
              role="option"
              aria-selected={i === active}
              className="composer-combobox-option"
              style={{
                padding: '6px 10px',
                fontSize: 14,
                cursor: 'pointer',
                background: i === active ? 'var(--surface-hover)' : 'var(--bg-elevated)',
                color: 'var(--text-primary)',
              }}
              onMouseDown={(e) => { e.preventDefault(); pick(o) }}
              onMouseEnter={() => setActive(i)}
            >
              {o}
            </div>
          ))}
        </div>,
        document.body,
      )}
    </div>
  )
}