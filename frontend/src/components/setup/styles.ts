import type React from 'react'

/**
 * The wizard's styles, built from the same design tokens as the rest of the
 * frontend (`design-tokens.css`). Nothing here invents a palette: colours,
 * radii, fonts and sizes are `var(--…)` so the wizard inherits the look of the
 * app it stands in front of, and a token change reaches it for free.
 *
 * The shape mirrors `AccessView.tsx`, the other full-screen gate in this app:
 * a centred column, surface-coloured cards, `btn btn-primary` / `btn btn-ghost`
 * for actions.
 */

export const pageStyle: React.CSSProperties = {
  display: 'flex',
  flexDirection: 'column',
  flex: 1,
  minHeight: 0,
  overflowY: 'auto',
  background: 'var(--bg-base)',
  color: 'var(--text-primary)',
  fontFamily: 'var(--font-sans)',
}

export const shellStyle: React.CSSProperties = {
  width: '100%',
  maxWidth: 880,
  margin: '0 auto',
  padding: '40px 24px 56px',
}

export const headerStyle: React.CSSProperties = {
  display: 'flex',
  alignItems: 'center',
  gap: 12,
  marginBottom: 8,
}

export const logoStyle: React.CSSProperties = {
  width: 32,
  height: 32,
  borderRadius: 'var(--radius-md)',
  objectFit: 'cover',
}

export const titleStyle: React.CSSProperties = {
  fontSize: 20,
  fontWeight: 600,
  letterSpacing: 'var(--tracking-tight)',
  lineHeight: 1.2,
  color: 'var(--text-primary)',
  outline: 'none',
}

export const subtitleStyle: React.CSSProperties = {
  fontSize: 13,
  lineHeight: 'var(--leading-relaxed)',
  color: 'var(--text-muted)',
  marginTop: 4,
}

export const sectionTitleStyle: React.CSSProperties = {
  fontSize: 16,
  fontWeight: 600,
  color: 'var(--text-primary)',
  outline: 'none',
}

export const railStyle: React.CSSProperties = {
  width: 208,
  flexShrink: 0,
}

export const railItemStyle = (active: boolean): React.CSSProperties => ({
  width: '100%',
  textAlign: 'left',
  padding: '8px 10px',
  marginBottom: 6,
  borderRadius: 'var(--radius-md)',
  border: '1px solid ' + (active ? 'var(--accent-primary)' : 'var(--border)'),
  background: active ? 'var(--bg-elevated)' : 'var(--bg-surface)',
  color: active ? 'var(--text-primary)' : 'var(--text-muted)',
  cursor: 'pointer',
  transition: 'background var(--duration-fast) ease, border-color var(--duration-fast) ease',
})

export const cardStyle: React.CSSProperties = {
  background: 'var(--bg-surface)',
  border: '1px solid var(--border)',
  borderRadius: 'var(--radius-lg)',
  padding: 20,
}

export const choiceStyle = (selected: boolean): React.CSSProperties => ({
  textAlign: 'left',
  padding: 12,
  borderRadius: 'var(--radius-md)',
  border: '1px solid ' + (selected ? 'var(--accent-primary)' : 'var(--border)'),
  background: selected ? 'var(--bg-elevated)' : 'var(--bg-sunken)',
  color: 'var(--text-primary)',
  cursor: 'pointer',
  transition: 'background var(--duration-fast) ease, border-color var(--duration-fast) ease',
})

export const choiceTitleStyle: React.CSSProperties = {
  display: 'block',
  fontSize: 14,
  fontWeight: 500,
  color: 'var(--text-primary)',
}

export const choiceBlurbStyle: React.CSSProperties = {
  display: 'block',
  fontSize: 12,
  lineHeight: 'var(--leading-normal)',
  color: 'var(--text-muted)',
  marginTop: 2,
}

export const labelStyle: React.CSSProperties = {
  display: 'block',
  fontSize: 12,
  fontWeight: 500,
  color: 'var(--text-muted)',
}

export const inputStyle: React.CSSProperties = {
  display: 'block',
  width: '100%',
  marginTop: 4,
  fontSize: 14,
  padding: '6px 10px',
  backgroundColor: 'var(--bg-sunken)',
  border: '1px solid var(--border)',
  borderRadius: 'var(--radius-sm)',
  color: 'var(--text-primary)',
  outline: 'none',
  fontFamily: 'inherit',
}

export const monoStyle: React.CSSProperties = {
  fontFamily: 'var(--font-mono)',
  fontSize: 12,
  lineHeight: 'var(--leading-normal)',
  background: 'var(--bg-sunken)',
  border: '1px solid var(--border)',
  borderRadius: 'var(--radius-md)',
  padding: '10px 12px',
  color: 'var(--text-muted)',
  overflowX: 'auto',
  whiteSpace: 'pre-wrap',
  wordBreak: 'break-all',
}

export const errorStyle: React.CSSProperties = {
  fontSize: 13,
  lineHeight: 'var(--leading-relaxed)',
  color: 'var(--needs-input)',
}

export const warningStyle: React.CSSProperties = {
  fontSize: 13,
  lineHeight: 'var(--leading-relaxed)',
  color: 'var(--warning)',
}

export const successStyle: React.CSSProperties = {
  fontSize: 13,
  lineHeight: 'var(--leading-relaxed)',
  color: 'var(--success)',
}

export const mutedStyle: React.CSSProperties = {
  fontSize: 13,
  lineHeight: 'var(--leading-relaxed)',
  color: 'var(--text-muted)',
}

export const faintStyle: React.CSSProperties = {
  fontSize: 12,
  lineHeight: 'var(--leading-relaxed)',
  color: 'var(--text-faint)',
}

export const primaryButtonClass = 'btn btn-primary px-3 py-2 rounded-lg text-sm font-medium'
export const ghostButtonClass = 'btn btn-ghost px-3 py-2 rounded-lg text-sm font-medium'
