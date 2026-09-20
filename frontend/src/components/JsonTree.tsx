import { useState } from 'react'

const INDENT_PX = 16

/**
 * Default field names used to build a preview string when an object is
 * collapsed.  Fields that exist in the object and appear in this list are
 * rendered as `key: value` pairs (truncated) on the collapsed preview line.
 */
const DEFAULT_PREVIEW_FIELDS = ['name', 'description', 'title', 'id']

/**
 * Maximum length of each field value in the collapsed preview.  Longer
 * values are truncated with an ellipsis character.
 */
const PREVIEW_FIELD_MAX_LEN = 60

interface JsonValueProps {
  value: unknown
  indent: number
  trailing: boolean
  keyPrefix: string | null
  defaultExpanded: boolean
  previewFields: string[]
}

export function JsonTree({ value, previewFields = DEFAULT_PREVIEW_FIELDS }: { value: unknown; previewFields?: string[] }) {
  return (
    <div className="json-tree" data-testid="formatted-json-body">
      <JsonValue value={value} indent={0} trailing={false} keyPrefix={null} defaultExpanded previewFields={previewFields} />
    </div>
  )
}

/**
 * Determine whether a value is "complex" — i.e. has multiple lines when
 * rendered and thus benefits from a collapse toggle.  Primitives and
 * single-line strings are not complex.  Objects, arrays, and multi-line
 * strings are complex.
 */
function isComplex(value: unknown): boolean {
  if (value === null) return false
  if (typeof value === 'object') return true
  if (typeof value === 'string' && value.includes('\n')) return true
  return false
}

/**
 * Produce a compact one-line preview of a value for display when the field
 * is collapsed.  Objects show `{…}`, arrays show `[…]`, multi-line strings
 * show the first line with an ellipsis, and primitives show their value.
 */
function previewText(value: unknown): string {
  if (value === null) return 'null'
  if (Array.isArray(value)) {
    if (value.length === 0) return '[]'
    return `[${value.length} ${value.length === 1 ? 'item' : 'items'}]`
  }
  if (typeof value === 'object') {
    const entries = Object.entries(value as Record<string, unknown>)
    if (entries.length === 0) return '{}'
    return `{${entries.length} ${entries.length === 1 ? 'key' : 'keys'}}`
  }
  if (typeof value === 'string') {
    if (value.includes('\n')) {
      const firstLine = value.split('\n')[0]!
      return firstLine.length > 80 ? `"${firstLine.slice(0, 80)}…"` : `"${firstLine}…"`
    }
    return `"${value}"`
  }
  return String(value)
}

/**
 * Truncate a string to `maxLen` characters, appending an ellipsis if
 * truncation occurred.  Returns the original string if it fits.
 */
function truncate(s: string, maxLen: number): string {
  if (s.length <= maxLen) return s
  return s.slice(0, maxLen) + '…'
}

/**
 * Render a single preview field value as a short string suitable for
 * inline display.  Strings are shown without their surrounding quotes
 * (the preview is already visually distinct via styling).  Primitives
 * are stringified.  Complex values (objects/arrays) are skipped — they
 * don't make useful one-line previews.
 */
function previewFieldValue(value: unknown): string | null {
  if (value === null) return 'null'
  if (typeof value === 'string') return truncate(value, PREVIEW_FIELD_MAX_LEN)
  if (typeof value === 'number' || typeof value === 'boolean') return String(value)
  // Objects, arrays, and multi-line strings are not useful as inline previews.
  return null
}

/**
 * Build a preview string for a collapsed object by extracting the values
 * of any configured preview fields that exist in the object.  Returns null
 * if no preview fields are present, in which case the caller should fall
 * back to the generic `{N keys}` summary.
 */
function objectPreview(value: Record<string, unknown>, previewFields: string[]): string | null {
  const parts: string[] = []
  for (const field of previewFields) {
    if (field in value) {
      const rendered = previewFieldValue(value[field])
      if (rendered !== null) {
        parts.push(`${field}: ${rendered}`)
      }
    }
  }
  if (parts.length === 0) return null
  return parts.join(', ')
}

function JsonValue({ value, indent, trailing, keyPrefix, defaultExpanded, previewFields }: JsonValueProps) {
  if (value === null) {
    return <PrimitiveRow indent={indent} keyPrefix={keyPrefix} trailing={trailing} className="json-null" text="null" />
  }
  const t = typeof value
  if (t === 'string') {
    return <StringRow value={value as string} indent={indent} trailing={trailing} keyPrefix={keyPrefix} defaultExpanded={defaultExpanded} />
  }
  if (t === 'number' || t === 'boolean') {
    return (
      <PrimitiveRow
        indent={indent}
        keyPrefix={keyPrefix}
        trailing={trailing}
        className={t === 'number' ? 'json-number' : 'json-boolean'}
        text={String(value)}
      />
    )
  }
  if (Array.isArray(value)) {
    return <ArrayNode value={value} indent={indent} trailing={trailing} keyPrefix={keyPrefix} defaultExpanded={defaultExpanded} previewFields={previewFields} />
  }
  if (t === 'object') {
    return (
      <ObjectNode
        value={value as Record<string, unknown>}
        indent={indent}
        trailing={trailing}
        keyPrefix={keyPrefix}
        defaultExpanded={defaultExpanded}
        previewFields={previewFields}
      />
    )
  }
  return (
    <PrimitiveRow
      indent={indent}
      keyPrefix={keyPrefix}
      trailing={trailing}
      className="json-string"
      text={String(value)}
    />
  )
}

function KeyPrefix({ name }: { name: string }) {
  return (
    <>
      <span className="json-key">"{name}"</span>
      <span className="json-punct">: </span>
    </>
  )
}

function PrimitiveRow({
  indent,
  keyPrefix,
  trailing,
  className,
  text,
}: {
  indent: number
  keyPrefix: string | null
  trailing: boolean
  className: string
  text: string
}) {
  return (
    <div className="json-row" style={{ paddingLeft: indent * INDENT_PX }}>
      {keyPrefix !== null && <KeyPrefix name={keyPrefix} />}
      <span className={className}>{text}</span>
      {trailing && <span className="json-punct">,</span>}
    </div>
  )
}

function StringRow({ value, indent, trailing, keyPrefix, defaultExpanded }: { value: string; indent: number; trailing: boolean; keyPrefix: string | null; defaultExpanded: boolean }) {
  const multiline = value.includes('\n')
  if (!multiline) {
    return (
      <div className="json-row" style={{ paddingLeft: indent * INDENT_PX }}>
        {keyPrefix !== null && <KeyPrefix name={keyPrefix} />}
        <span className="json-string">"{value}"</span>
        {trailing && <span className="json-punct">,</span>}
      </div>
    )
  }
  // Multi-line string with a collapse toggle.
  return (
    <MultilineStringRow value={value} indent={indent} trailing={trailing} keyPrefix={keyPrefix} defaultExpanded={defaultExpanded} />
  )
}

function Toggle({ expanded, onToggle }: { expanded: boolean; onToggle: () => void }) {
  return (
    <button
      type="button"
      className="json-toggle"
      aria-label={expanded ? 'Collapse' : 'Expand'}
      onClick={onToggle}
    >
      {expanded ? '−' : '+'}
    </button>
  )
}

/**
 * Multi-line string rendered with its own collapse toggle.  When collapsed,
 * shows the first line as a preview.  When expanded, shows the full string
 * in a <pre> block.
 */
function MultilineStringRow({
  value,
  indent,
  trailing,
  keyPrefix,
  defaultExpanded,
}: {
  value: string
  indent: number
  trailing: boolean
  keyPrefix: string | null
  defaultExpanded: boolean
}) {
  const [expanded, setExpanded] = useState(defaultExpanded)
  const firstLine = value.split('\n')[0]!
  const preview = firstLine.length > 80 ? `"${firstLine.slice(0, 80)}…"` : `"${firstLine}…"`

  if (!expanded) {
    return (
      <div className="json-row" style={{ paddingLeft: indent * INDENT_PX }}>
        <Toggle expanded={false} onToggle={() => setExpanded(true)} />
        {keyPrefix !== null && <KeyPrefix name={keyPrefix} />}
        <span className="json-collapsed-preview">{preview}</span>
        {trailing && <span className="json-punct">,</span>}
      </div>
    )
  }

  return (
    <>
      <div className="json-row" style={{ paddingLeft: indent * INDENT_PX }}>
        <Toggle expanded onToggle={() => setExpanded(false)} />
        {keyPrefix !== null && <KeyPrefix name={keyPrefix} />}
        <span className="json-string">"</span>
      </div>
      <pre className="json-string-block" style={{ marginLeft: (indent + 1) * INDENT_PX }}>{value}</pre>
      <div className="json-row" style={{ paddingLeft: indent * INDENT_PX }}>
        <span className="json-string">"</span>
        {trailing && <span className="json-punct">,</span>}
      </div>
    </>
  )
}

function ObjectNode({
  value,
  indent,
  trailing,
  keyPrefix,
  defaultExpanded,
  previewFields,
}: {
  value: Record<string, unknown>
  indent: number
  trailing: boolean
  keyPrefix: string | null
  defaultExpanded: boolean
  previewFields: string[]
}) {
  const [expanded, setExpanded] = useState(defaultExpanded)
  const entries = Object.entries(value)

  if (entries.length === 0) {
    return (
      <div className="json-row" style={{ paddingLeft: indent * INDENT_PX }}>
        <span className="json-toggle-spacer" aria-hidden="true" />
        {keyPrefix !== null && <KeyPrefix name={keyPrefix} />}
        <span className="json-punct">{'{}'}</span>
        {trailing && <span className="json-punct">,</span>}
      </div>
    )
  }

  // When collapsed, show the opening brace line with toggle and a preview.
  // If the object has any of the configured preview fields, show their
  // values instead of the generic "{N keys}" count.
  if (!expanded) {
    const preview = objectPreview(value, previewFields) ?? previewText(value)
    return (
      <div className="json-row" style={{ paddingLeft: indent * INDENT_PX }}>
        <Toggle expanded={false} onToggle={() => setExpanded(true)} />
        {keyPrefix !== null && <KeyPrefix name={keyPrefix} />}
        <span className="json-punct">{'{'}</span>
        <span className="json-collapsed-preview"> {preview} </span>
        <span className="json-punct">{'}'}</span>
        {trailing && <span className="json-punct">,</span>}
      </div>
    )
  }

  return (
    <>
      <div className="json-row" style={{ paddingLeft: indent * INDENT_PX }}>
        <Toggle expanded onToggle={() => setExpanded(false)} />
        {keyPrefix !== null && <KeyPrefix name={keyPrefix} />}
        <span className="json-punct">{'{'}</span>
      </div>
      {entries.map(([k, v], i) => (
        <FieldValue
          key={k}
          fieldKey={k}
          value={v}
          indent={indent + 1}
          trailing={i < entries.length - 1}
          defaultExpanded={false}
          previewFields={previewFields}
        />
      ))}
      <div className="json-row" style={{ paddingLeft: indent * INDENT_PX }}>
        <span className="json-punct">{'}'}</span>
        {trailing && <span className="json-punct">,</span>}
      </div>
    </>
  )
}

function ArrayNode({
  value,
  indent,
  trailing,
  keyPrefix,
  defaultExpanded,
  previewFields,
}: {
  value: unknown[]
  indent: number
  trailing: boolean
  keyPrefix: string | null
  defaultExpanded: boolean
  previewFields: string[]
}) {
  const [expanded, setExpanded] = useState(defaultExpanded)

  if (value.length === 0) {
    return (
      <div className="json-row" style={{ paddingLeft: indent * INDENT_PX }}>
        <span className="json-toggle-spacer" aria-hidden="true" />
        {keyPrefix !== null && <KeyPrefix name={keyPrefix} />}
        <span className="json-punct">{'[]'}</span>
        {trailing && <span className="json-punct">,</span>}
      </div>
    )
  }

  if (!expanded) {
    return (
      <div className="json-row" style={{ paddingLeft: indent * INDENT_PX }}>
        <Toggle expanded={false} onToggle={() => setExpanded(true)} />
        {keyPrefix !== null && <KeyPrefix name={keyPrefix} />}
        <span className="json-punct">{'['}</span>
        <span className="json-collapsed-preview"> {previewText(value)} </span>
        <span className="json-punct">{']'}</span>
        {trailing && <span className="json-punct">,</span>}
      </div>
    )
  }

  return (
    <>
      <div className="json-row" style={{ paddingLeft: indent * INDENT_PX }}>
        <Toggle expanded onToggle={() => setExpanded(false)} />
        {keyPrefix !== null && <KeyPrefix name={keyPrefix} />}
        <span className="json-punct">{'['}</span>
      </div>
      {value.map((v, i) => (
        <FieldValue
          key={i}
          fieldKey={null}
          value={v}
          indent={indent + 1}
          trailing={i < value.length - 1}
          defaultExpanded={false}
          previewFields={previewFields}
        />
      ))}
      <div className="json-row" style={{ paddingLeft: indent * INDENT_PX }}>
        <span className="json-punct">{']'}</span>
        {trailing && <span className="json-punct">,</span>}
      </div>
    </>
  )
}

/**
 * Renders a single field (key + value) inside an object or array.
 * Decides whether to show a collapse toggle based on whether the value
 * is complex (objects, arrays, multi-line strings).
 *
 * - Complex values get a +/- toggle and are collapsed by default.
 * - Simple values (primitives, single-line strings) render inline with
 *   no toggle.
 */
function FieldValue({
  fieldKey,
  value,
  indent,
  trailing,
  defaultExpanded,
  previewFields,
}: {
  fieldKey: string | null
  value: unknown
  indent: number
  trailing: boolean
  defaultExpanded: boolean
  previewFields: string[]
}) {
  // For complex values, use the existing node components which already
  // handle their own toggle.  The `defaultExpanded` controls the initial
  // state.
  if (isComplex(value)) {
    return (
      <JsonValue
        value={value}
        indent={indent}
        trailing={trailing}
        keyPrefix={fieldKey}
        defaultExpanded={defaultExpanded}
        previewFields={previewFields}
      />
    )
  }

  // Simple values: render inline with no toggle, but reserve the toggle
  // space for alignment.
  return (
    <div className="json-row" style={{ paddingLeft: indent * INDENT_PX }}>
      <span className="json-toggle-spacer" aria-hidden="true" />
      {fieldKey !== null && <KeyPrefix name={fieldKey} />}
      {value === null ? (
        <span className="json-null">null</span>
      ) : typeof value === 'string' ? (
        <span className="json-string">"{value}"</span>
      ) : typeof value === 'number' ? (
        <span className="json-number">{String(value)}</span>
      ) : typeof value === 'boolean' ? (
        <span className="json-boolean">{String(value)}</span>
      ) : (
        <span className="json-string">{String(value)}</span>
      )}
      {trailing && <span className="json-punct">,</span>}
    </div>
  )
}
