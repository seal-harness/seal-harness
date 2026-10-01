import { useState, useRef, useEffect } from 'react'
import {
  type TabLineField,
  TAB_LINE_FIELD_LABELS,
  ALL_TAB_LINE_FIELDS,
  moveFieldUp,
  moveFieldDown,
  toggleField,
} from '../lib/tabLineConfig'

/** A bottom bar for the sidebar with a small gear icon that opens a popover
 *  for configuring which fields appear on each tab row's second line and in
 *  what order. The bar itself is `var(--bottombar-height)` tall so its bottom
 *  edge aligns with the ChatArea's BottomBar (the "status line below the
 *  transcript area").
 *
 *  The popover shows:
 *    - A checkbox per available field (toggle visibility)
 *    - Up/down arrows per enabled field (reorder)
 *  Changes are applied immediately (live preview) and persisted by the
 *  parent via the `onFieldsChange` callback. */

export function TabLineConfigBar({
  fields,
  onFieldsChange,
}: {
  fields: TabLineField[]
  onFieldsChange: (fields: TabLineField[]) => void
}) {
  const [open, setOpen] = useState(false)
  const containerRef = useRef<HTMLDivElement>(null)

  // Close the popover on outside click.
  useEffect(() => {
    if (!open) return
    function handleClick(e: MouseEvent) {
      if (containerRef.current && !containerRef.current.contains(e.target as Node)) {
        setOpen(false)
      }
    }
    document.addEventListener('mousedown', handleClick)
    return () => document.removeEventListener('mousedown', handleClick)
  }, [open])

  return (
    <div
      ref={containerRef}
      className="shrink-0 relative"
      data-testid="tab-line-config-bar"
      style={{
        height: 'var(--bottombar-height)',
        background: 'var(--bg-surface)',
        borderTop: '1px solid var(--border)',
      }}
    >
      <div className="h-full flex items-center px-3">
        <button
          type="button"
          className="btn btn-ghost flex items-center justify-center"
          style={{ width: 22, height: 22, padding: 0, lineHeight: 1 }}
          onClick={() => setOpen((v) => !v)}
          aria-label="Configure tab fields"
          title="Configure tab fields"
          data-testid="tab-line-config-button"
        >
          <svg
            width="14" height="14" viewBox="0 0 16 16" fill="none"
            stroke="currentColor" strokeWidth="1.4" strokeLinecap="round" strokeLinejoin="round"
            aria-hidden="true"
          >
            <path d="M8 5.5 a2.5 2.5 0 1 0 0 5 a2.5 2.5 0 1 0 0 -5" />
            <path d="M8 1.5 v1.5 M8 13 v1.5 M3.2 3.2 l1.1 1.1 M11.7 11.7 l1.1 1.1 M1.5 8 h1.5 M13 8 h1.5 M3.2 12.8 l1.1 -1.1 M11.7 4.3 l1.1 -1.1" />
          </svg>
        </button>
        <span
          className="text-xs ml-2"
          style={{ color: 'var(--text-faint)' }}
        >
          {fields.map((f) => TAB_LINE_FIELD_LABELS[f]).join(' · ')}
        </span>
      </div>

      {open && (
        <div
          data-testid="tab-line-config-popover"
          className="absolute bottom-full left-0 right-0 z-50"
          style={{
            background: 'var(--bg-elevated)',
            border: '1px solid var(--border)',
            borderRadius: 'var(--radius-md)',
            boxShadow: '0 -4px 12px rgba(0,0,0,0.3)',
            maxHeight: '300px',
            overflowY: 'auto',
          }}
        >
          <div
            className="px-3 py-2 text-xs font-semibold uppercase"
            style={{ color: 'var(--text-muted)', letterSpacing: '0.08em' }}
          >
            Tab Fields
          </div>
          {ALL_TAB_LINE_FIELDS.map((field) => {
            const enabled = fields.includes(field)
            const idx = fields.indexOf(field)
            return (
              <div
                key={field}
                className="flex items-center gap-2 px-3 py-1.5"
                data-testid={`tab-line-config-row-${field}`}
                style={{ color: 'var(--text-muted)' }}
              >
                <label className="flex items-center gap-2 flex-1 cursor-pointer">
                  <input
                    type="checkbox"
                    checked={enabled}
                    onChange={() => onFieldsChange(toggleField(fields, field))}
                    aria-label={TAB_LINE_FIELD_LABELS[field]}
                  />
                  <span className="text-xs">{TAB_LINE_FIELD_LABELS[field]}</span>
                </label>
                {enabled && (
                  <span className="flex items-center gap-0.5">
                    <button
                      type="button"
                      className="btn btn-ghost"
                      style={{ width: 20, height: 20, padding: 0, fontSize: 10, lineHeight: 1 }}
                      disabled={idx <= 0}
                      onClick={() => onFieldsChange(moveFieldUp(fields, field))}
                      aria-label={`Move ${TAB_LINE_FIELD_LABELS[field]} up`}
                      data-testid={`tab-line-config-up-${field}`}
                    >
                      ▲
                    </button>
                    <button
                      type="button"
                      className="btn btn-ghost"
                      style={{ width: 20, height: 20, padding: 0, fontSize: 10, lineHeight: 1 }}
                      disabled={idx < 0 || idx >= fields.length - 1}
                      onClick={() => onFieldsChange(moveFieldDown(fields, field))}
                      aria-label={`Move ${TAB_LINE_FIELD_LABELS[field]} down`}
                      data-testid={`tab-line-config-down-${field}`}
                    >
                      ▼
                    </button>
                  </span>
                )}
              </div>
            )
          })}
        </div>
      )}
    </div>
  )
}