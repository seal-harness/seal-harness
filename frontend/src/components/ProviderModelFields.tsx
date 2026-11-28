import { useEffect, useRef, useState } from 'react'
import { createPortal } from 'react-dom'
import type { ProviderInfo, ProviderReadiness } from '../types'
import { isOfferableProvider, readinessLabel } from '../lib/readiness'

/** Human labels for provider ids. An id this build does not know still renders
 *  as itself, never as an empty string and never as an error. */
export const PROVIDER_LABELS: Record<string, string> = {
  anthropic: 'Anthropic',
  'ollama-cloud': 'Ollama Cloud',
  openai: 'OpenAI',
  'openai-compatible': 'OpenAI-compatible',
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
  /** Ollama's observed readiness. Absent for every other provider, and for a
   *  backend that does not send it yet. */
  readiness?: ProviderReadiness
  /** The usable-model count for `readiness: 'ready'`. Snake_case because this
   *  interface is satisfied structurally by `ProviderInfo`, which mirrors
   *  `GET /api/providers` — the endpoint that keeps its own lowercase casing. */
  readiness_models?: number
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

/** Can this provider appear as an option?
 *
 *  Included when any of these holds:
 *
 *  - it is the control's current value (see below);
 *  - it is stored but unresolved (`missing`) — hiding it would let an edit
 *    silently clear the value, the same guard the Cron agent picker uses;
 *  - `isOfferableProvider` says so: configured, and not positively absent.
 *
 *  That last clause is the fix for the reported bug. A keyless local Ollama is
 *  `configured: true` whether or not anything is installed (`configured` is
 *  config-only by design), so a machine with no Ollama still offered "Ollama
 *  (Ollama Not Found)" here — an option that cannot answer the turn it is
 *  picked for. The absence filter is deliberately narrow: see `isNotInstalled`
 *  for why `not-running` and `no-models` stay listed. */
function isSelectable(p: ProviderOption, current: string): boolean {
  // The control's own value is never hidden. A <select> whose value has no
  // matching option renders blank and, on the next change event, reports
  // whatever the browser substitutes — so hiding a stored-but-unusable
  // provider here would silently rewrite the operator's saved choice (and,
  // for the Cron editor, drop it on the next save). "Cannot be picked afresh"
  // and "must disappear from under an existing selection" are different
  // questions; only the first is ours to answer.
  if (p.name === current) return true
  if (p.missing === true) return true
  return isOfferableProvider(p)
}

/** The provider `<select>` shared by the "Start a new tab" composer and the
 *  Cron editor. The two call sites differ only in whether the leading
 *  "use configured default" option is shown and whether an empty list should
 *  render the no-providers notice. */
export function ProviderSelect({
  id, value, onChange, providers, loading, disabled, showDefaultOption, showNoProvidersNotice,
}: ProviderSelectProps) {
  const selectable = providers.filter((p) => isSelectable(p, value))
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
          {/* Two causes reach this branch, so the copy names both rather than
              asserting `configured` is false: nothing is configured, or what
              is configured cannot be offered here (an Ollama that is not
              installed). */}
          (no usable providers — set an API key or install Ollama)
        </option>
      )}
      {showDefaultOption && <option value="">(use configured default)</option>}
      {!loading && selectable.map((p) => (
        <option key={p.name} value={p.name}>
          {PROVIDER_LABELS[p.name] ?? p.name}
          {p.isDefault ? ' (default)' : ''}
          {/* `missing` wins over readiness when both apply: it is the stronger
              statement (the stored id does not resolve at all). Readiness is
              otherwise an annotation; every state except `not-installed` was
              already filtered in, and a surviving `not-installed` can only be
              the current value, where the label is exactly what the operator
              needs to see. */}
          {p.missing ? ' (missing)' : optionReadinessAnnotation(p)}
        </option>
      ))}
    </select>
  )
}

/** The parenthesised readiness annotation for an Ollama option, or the empty
 *  string. Parenthesised to match the existing ` (default)` / ` (missing)`
 *  annotations rather than inventing a dash. `pending` renders nothing: it is
 *  "we have not looked yet", not a state worth annotating. */
function optionReadinessAnnotation(p: ProviderOption): string {
  if (p.name !== 'ollama' || p.readiness === undefined) return ''
  const label = readinessLabel(p.readiness, p.readiness_models)
  return label === '' ? '' : ` (${label})`
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
