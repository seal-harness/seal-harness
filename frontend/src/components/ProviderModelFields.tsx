import { useEffect, useRef, useState } from 'react'
import { createPortal } from 'react-dom'
import type { ProviderInfo } from '../types'

/** Human labels for provider ids. An id this build does not know still renders
 *  as itself, never as an empty string and never as an error. */
export const PROVIDER_LABELS: Record<string, string> = {
  anthropic: 'Anthropic',
  openai: 'OpenAI-compatible',
  openrouter: 'OpenRouter',
  ollama: 'Ollama',
}

/** The shared input geometry. Both the "Start a new tab" composer and the
 *  Cron editor use it, so the two forms' controls line up. */
export const inputStyle: React.CSSProperties = {
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

/** One entry in the provider picker.
 *
 *  `missing` renders a stored-but-unresolvable id so an edit cannot silently
 *  clear it (the same guard the Cron agent picker uses). */
export interface ProviderOption {
  name: string
  isDefault?: boolean
  configured?: boolean
  missing?: boolean
}

interface ProviderSelectProps {
  id: string
  value: string
  onChange: (v: string) => void
  providers: ProviderOption[]
  /** True once the provider list has been fetched. Until then the control
   *  shows a loading entry rather than pretending the list is empty. */
  loading: boolean
  disabled?: boolean
  /** Render a leading empty-valued "(use configured default)" option. */
  showDefaultOption?: boolean
  /** Render the no-providers-configured notice when the list is empty. */
  showNoProvidersNotice?: boolean
}

/** The provider `<select>` shared by the "Start a new tab" composer and the
 *  Cron editor. The two call sites differ only in whether the leading
 *  "use configured default" option is shown and whether an empty list should
 *  render the no-providers notice. */
export function ProviderSelect({
  id, value, onChange, providers, loading, disabled, showDefaultOption, showNoProvidersNotice,
}: ProviderSelectProps) {
  const selectable = providers.filter((p) => p.configured !== false || p.missing === true)
  const noProviders = !loading && selectable.length === 0
  return (
    <select
      id={id}
      value={value}
      onChange={(e) => onChange(e.target.value)}
      disabled={disabled || loading || noProviders}
      className="composer-select"
      style={inputStyle}
    >
      {loading && <option value="">Loading…</option>}
      {noProviders && showNoProvidersNotice && (
        <option value="" disabled>
          (no providers configured — set an API key or start Ollama)
        </option>
      )}
      {showDefaultOption && <option value="">(use configured default)</option>}
      {!loading && selectable.map((p) => (
        <option key={p.name} value={p.name}>
          {PROVIDER_LABELS[p.name] ?? p.name}
          {p.isDefault ? ' (default)' : ''}
          {p.missing ? ' (missing)' : ''}
        </option>
      ))}
    </select>
  )
}

/** A self-contained combobox: a text input (free entry) plus a left-aligned
 *  popup of suggestions. Replaces the native <datalist>, whose popup position
 *  is browser-controlled (Chrome centers it under the input, ignoring CSS) and
 *  whose native ▾ indicator fights our shared chevron.
 *
 *  The popup is rendered through a React Portal to document.body so it escapes
 *  the composer's clipping ancestor (`overflow-y-auto` on the wrapper in
 *  App.tsx) — without the portal the absolutely-positioned popup is clipped
 *  to the scroll container and never visible. Its position is derived from the
 *  input's getBoundingClientRect() so it stays left-aligned to the input box
 *  like the <select> dropdowns. The popup re-positions on scroll/resize while
 *  open so it tracks the input if the composer scrolls. The input carries the
 *  .composer-datalist class so it gets the same chevron and 10px left text
 *  inset as the other composer controls. */
export function CustomModelCombobox({
  id, value, onChange, options, placeholder, testId,
}: {
  id: string
  value: string
  onChange: (v: string) => void
  options: string[]
  placeholder?: string
  testId?: string
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
          data-testid={testId ?? 'provider-model-custom-list'}
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

/** The two labelled rows shared by the "Start a new tab" composer and the Cron
 *  editor: a provider picker and a model combobox. The caller supplies the
 *  containing `Row` layout, so the two forms keep their own geometry.
 *
 *  The model is never auto-filled: an empty model means "use Seal's configured
 *  default model", and the caller omits the field entirely in that case. */
export function ProviderModelFields({
  providerId, modelId,
  provider, setProvider,
  model, setModel,
  providers, providersLoading,
  modelOptions, modelsLoading,
  showDefaultOption, showNoProvidersNotice,
  modelDisabled, modelPlaceholder,
  modelTestId,
  renderRow,
}: {
  providerId: string
  modelId: string
  provider: string
  setProvider: (v: string) => void
  model: string
  setModel: (v: string) => void
  providers: ProviderInfo[]
  providersLoading: boolean
  modelOptions: string[]
  modelsLoading: boolean
  showDefaultOption?: boolean
  showNoProvidersNotice?: boolean
  modelDisabled?: boolean
  modelPlaceholder?: string
  modelTestId?: string
  /** Each call site wraps a control in its own Row so the shared component
   *  stays layout-agnostic. */
  renderRow: (label: string, htmlFor: string, control: React.ReactNode) => React.ReactNode
}) {
  return (
    <>
      {renderRow(
        'Provider',
        providerId,
        <ProviderSelect
          id={providerId}
          value={provider}
          onChange={setProvider}
          providers={providers}
          loading={providersLoading}
          showDefaultOption={showDefaultOption}
          showNoProvidersNotice={showNoProvidersNotice}
        />,
      )}
      {renderRow(
        'Model',
        modelId,
        modelDisabled
          ? (
            <input
              id={modelId}
              type="text"
              value=""
              disabled
              className="composer-datalist"
              style={inputStyle}
              placeholder={modelPlaceholder}
            />
          )
          : (
            <CustomModelCombobox
              id={modelId}
              value={model}
              onChange={setModel}
              options={modelOptions}
              placeholder={modelPlaceholder ?? 'model id (pick a suggestion or type your own)'}
              testId={modelTestId}
            />
          ),
      )}
      {modelsLoading && !modelDisabled && (
        <div style={{ fontSize: 11, color: 'var(--text-faint)' }}>Loading models…</div>
      )}
    </>
  )
}
