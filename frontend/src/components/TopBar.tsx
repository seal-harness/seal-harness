import { useEffect, useRef, useState } from 'react'
import logoImg from '../../assets/SealLogo.png'

/** The top-level navigation sections. The existing sessions/tabs/chat UI
 *  lives under "Sessions"; "Agents" + "Skills" open the CRUD views. */
export type TopSection = 'sessions' | 'agents' | 'skills'

const SECTION_LABELS: Record<TopSection, string> = {
  sessions: 'Sessions',
  agents: 'Agents',
  skills: 'Skills',
}

export function TopBar({
  section,
  onSectionChange,
}: {
  section: TopSection
  onSectionChange: (s: TopSection) => void
}) {
  return (
    <div
      className="topbar-bg flex items-center px-4 gap-4 shrink-0"
      style={{ height: 'var(--topbar-height)', borderBottom: '1px solid var(--border)' }}
    >
      <div className="flex items-center gap-2.5">
        <img
          src={logoImg}
          alt="Seal Harness"
          style={{ width: 'var(--logo-size)', height: 'var(--logo-size)', borderRadius: 'var(--radius-md)', objectFit: 'cover' }}
        />
        <span
          className="font-semibold text-sm"
          style={{ color: 'var(--text-primary)', letterSpacing: 'var(--tracking-tighter)' }}
        >
          Seal Harness
        </span>
      </div>

      {/* Top-level menu */}
      <nav className="flex items-center gap-1" aria-label="Top-level sections">
        {(Object.keys(SECTION_LABELS) as TopSection[]).map((s) => (
          <SectionButton
            key={s}
            label={SECTION_LABELS[s]}
            active={section === s}
            onClick={() => onSectionChange(s)}
          />
        ))}
      </nav>

      <div className="flex-1" />

      <div className="flex items-center gap-2">
        <div
          className="text-xs px-2.5 py-1.5 rounded-md flex items-center"
          style={{ background: 'var(--bg-elevated)', color: 'var(--text-faint)', border: '1px solid var(--border)' }}
        >
          v0.1.0
        </div>
      </div>
    </div>
  )
}

function SectionButton({
  label, active, onClick,
}: { label: string; active: boolean; onClick: () => void }) {
  const [hovered, setHovered] = useState(false)
  const ref = useRef<HTMLButtonElement>(null)
  // Keep hover state in sync with focus for keyboard navigation parity.
  useEffect(() => {
    const el = ref.current
    if (!el) return
    const onF = () => setHovered(true)
    const onB = () => setHovered(false)
    el.addEventListener('focus', onF)
    el.addEventListener('blur', onB)
    return () => {
      el.removeEventListener('focus', onF)
      el.removeEventListener('blur', onB)
    }
  }, [])
  const bg = active
    ? 'var(--bg-elevated)'
    : hovered
      ? 'var(--surface-hover)'
      : 'transparent'
  const color = active ? 'var(--text-primary)' : 'var(--text-muted)'
  return (
    <button
      ref={ref}
      type="button"
      onClick={onClick}
      onMouseEnter={() => setHovered(true)}
      onMouseLeave={() => setHovered(false)}
      aria-current={active ? 'page' : undefined}
      data-testid={`section-${label.toLowerCase()}`}
      className="text-sm font-medium rounded-md"
      style={{
        padding: '5px 10px',
        background: bg,
        color,
        border: active ? '1px solid var(--border)' : '1px solid transparent',
        transition: 'background var(--duration-fast) var(--ease-out), color var(--duration-fast) var(--ease-out)',
      }}
    >
      {label}
    </button>
  )
}