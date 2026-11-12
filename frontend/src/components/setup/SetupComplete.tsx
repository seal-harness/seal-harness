import { useEffect, useRef } from 'react'
import * as s from './styles'

/**
 * The final screen. It does not auto-continue: the operator clicks "Start
 * chatting", which asks the gate to reveal the app. Auto-continuing on mount
 * would yank the completion confirmation away before it could be read, and
 * would fire an extra probe on every render of a step that is already finished.
 */
export function SetupComplete({ onComplete }: { onComplete: () => void }) {
  const headingRef = useRef<HTMLHeadingElement | null>(null)
  useEffect(() => {
    headingRef.current?.focus()
  }, [])
  return (
    <section style={s.cardStyle}>
      <h2 ref={headingRef} tabIndex={-1} style={s.sectionTitleStyle}>
        Setup complete
      </h2>
      <p style={{ ...s.mutedStyle, marginTop: 8 }}>
        Your vault and your LLM provider are configured. Everything else can be
        changed later from the terminal with{' '}
        <code style={{ fontFamily: 'var(--font-mono)' }}>seal tui</code>.
      </p>
      <button
        type="button"
        onClick={onComplete}
        className={s.primaryButtonClass}
        style={{ marginTop: 20 }}
      >
        Start chatting
      </button>
    </section>
  )
}
