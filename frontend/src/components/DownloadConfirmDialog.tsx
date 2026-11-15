import { useEffect, useRef } from 'react'
import { createPortal } from 'react-dom'
import { openModalStack } from '../lib/modalStack'

export interface DownloadConfirmDialogProps {
  /** Full path of the file being downloaded. */
  path: string
  /** File size in bytes (from stat). */
  size: number
  /** Configured prompt threshold in bytes. */
  threshold: number
  /** Called when the user chooses Cancel. */
  onCancel: () => void
  /** Called when the user chooses Download partial. */
  onPartial: () => void
  /** Called when the user chooses Download full anyway. */
  onFull: () => void
}

function formatBytes(n: number): string {
  if (n < 1024) return `${n} B`
  if (n < 1024 * 1024) return `${(n / 1024).toFixed(1)} KiB`
  if (n < 1024 * 1024 * 1024) return `${(n / (1024 * 1024)).toFixed(1)} MiB`
  return `${(n / (1024 * 1024 * 1024)).toFixed(2)} GiB`
}

export function DownloadConfirmDialog({
  path, size, threshold, onCancel, onPartial, onFull,
}: DownloadConfirmDialogProps) {
  const cancelBtnRef = useRef<HTMLButtonElement>(null)
  const onCancelRef = useRef(onCancel)
  onCancelRef.current = onCancel

  useEffect(() => {
    const id = Symbol('download-confirm')
    openModalStack.push(id)
    const previouslyFocused = (document.activeElement as HTMLElement | null) ?? null
    cancelBtnRef.current?.focus()

    const onKey = (e: KeyboardEvent) => {
      if (e.key !== 'Escape') return
      if (openModalStack[openModalStack.length - 1] !== id) return
      e.stopPropagation()
      onCancelRef.current()
    }
    window.addEventListener('keydown', onKey)

    return () => {
      window.removeEventListener('keydown', onKey)
      const idx = openModalStack.indexOf(id)
      if (idx >= 0) openModalStack.splice(idx, 1)
      previouslyFocused?.focus?.()
    }
  }, [])

  const basename = path.split('/').pop() || path
  const sizeStr = formatBytes(size)
  const thresholdStr = formatBytes(threshold)

  return createPortal(
    <div
      role="dialog"
      aria-modal="true"
      aria-labelledby="download-confirm-title"
      data-testid="download-confirm-dialog"
      style={{
        position: 'fixed', inset: 0, zIndex: 10000,
        display: 'flex', alignItems: 'center', justifyContent: 'center',
        background: 'rgba(0,0,0,0.5)',
      }}
    >
      <div
        style={{
          background: 'var(--surface)', borderRadius: 8, padding: 24,
          maxWidth: 480, boxShadow: '0 8px 32px rgba(0,0,0,.3)',
        }}
      >
        <h2 id="download-confirm-title" style={{ marginTop: 0 }}>
          Download {formatBytes(size)} file?
        </h2>
        <p style={{ color: 'var(--text-muted)' }}>
          This file ({basename}) exceeds the configured prompt threshold of{' '}
          <strong>{thresholdStr}</strong>.
        </p>
        <div style={{ display: 'flex', flexDirection: 'column', gap: 12, marginTop: 16 }}>
          <button onClick={onCancel} ref={cancelBtnRef} style={btnStyle}>
            Cancel — do nothing
          </button>
          <button
            onClick={onPartial}
            style={{ ...btnStyle, color: 'var(--warning)' }}
            data-testid="download-partial-btn"
          >
            Download partial — save only the first {thresholdStr}, as .partial.
            <span style={{ display: 'block', fontSize: '0.85em', marginTop: 4 }}>
              The saved file will be incomplete and unusable for archives,
              installers, or media (.zip, .tar.gz, .pdf, .mp4).
            </span>
          </button>
          <button
            onClick={onFull}
            style={{ ...btnStyle, fontWeight: 'bold' }}
            data-testid="download-full-btn"
          >
            Download full anyway — save all {sizeStr}
          </button>
        </div>
      </div>
    </div>,
    document.body,
  )
}

const btnStyle: React.CSSProperties = {
  padding: '8px 16px', borderRadius: 4, cursor: 'pointer',
  border: '1px solid var(--border)', background: 'var(--surface)',
  textAlign: 'left',
}
