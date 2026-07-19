import { useEffect, useRef, useState } from 'react'
import { createPortal } from 'react-dom'
import {
  CUSTOM_MODEL_VALUE,
  type NewTabSpec,
} from '../hooks/useNewTabSpec'
import { createBareSession, type NewBareSessionResponse } from '../hooks/useApi'

const PROVIDER_LABELS: Record<string, string> = {
  anthropic: 'Anthropic',
  openai: 'OpenAI',
  openrouter: 'OpenRouter',
  ollama: 'Ollama',
}

// ── Props ─────────────────────────────────────────────────────────────

interface NewSessionComposerProps {
  spec: NewTabSpec
  /** Called after a successful createBareSession. The response carries the
   *  new session id so the parent can navigate to it. */
  onSubmit: (res: NewBareSessionResponse) => void
  onCancel: () => void
}

// ── Component ─────────────────────────────────────────────────────────

/** The "New session" composer — a single-section form (AI Provider) that
 *  creates a bare session (no tab attached) and focuses it. Mirrors the
 *  AI Provider section of NewTabComposer, but without the kind pills or
 *  the Harness/Attach sections. Reuses the shared `NewTabSpec` hook so the
 *  provider/model selection + persisted last-options are consistent with
 *  the "New tab" flow. */
export function NewSessionComposer({ spec, onSubmit, onCancel }: NewSessionComposerProps) {
  const noProviders = spec.providersLoaded && spec.configuredProviders.length === 0
  const [submitting, setSubmitting] = useState(false)

  const handleSubmit = async () => {
    if (spec.validationError) return
    setSubmitting(true)
    const res = await createBareSession({ provider: spec.provider, model: spec.model.trim() })
    setSubmitting(false)
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
        Start a new session
      </div>

      <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
        <Row label="Provider" htmlFor="ns-provider-select">
          <select
            id="ns-provider-select"
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

        <Row label="Model" htmlFor="ns-provider-model">
          <select
            id="ns-provider-model"
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
          <Row label="Custom Model" htmlFor="ns-provider-model-custom">
            <CustomModelCombobox
              id="ns-provider-model-custom"
              value={spec.model}
              onChange={spec.setModel}
              options={spec.customModels}
              placeholder="model id (e.g. claude-3-opus-20240229)"
            />
          </Row>
        )}
      </div>

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
          disabled={spec.validationError !== null || submitting}
          aria-label="Submit new session"
        >
          Start
        </button>
      </div>
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

// ── Custom Model combobox (mirrors NewTabComposer's; kept here so the
//    new-session composer is self-contained without reaching into
//    NewTabComposer's private helpers). ────────────────────────────────
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
          data-testid="ns-provider-model-custom-list"
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