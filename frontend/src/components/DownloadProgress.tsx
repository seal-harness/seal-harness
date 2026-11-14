import type { DownloadProgress } from '../hooks/useFileDownload'

export interface DownloadProgressUIProps {
  progress: DownloadProgress
  onCancel: () => void
  onRetry: () => void
}

function formatBytes(n: number): string {
  if (n < 1024) return `${n} B`
  if (n < 1024 * 1024) return `${(n / 1024).toFixed(1)} KiB`
  if (n < 1024 * 1024 * 1024) return `${(n / (1024 * 1024)).toFixed(1)} MiB`
  return `${(n / (1024 * 1024 * 1024)).toFixed(2)} GiB`
}

function formatEta(seconds: number | null): string {
  if (seconds === null) return 'estimating…'
  if (seconds <= 0) return 'almost done'
  if (seconds < 60) return `${Math.ceil(seconds)}s remaining`
  const mins = Math.floor(seconds / 60)
  const secs = Math.ceil(seconds % 60)
  if (mins < 60) return `${mins}m ${secs}s remaining`
  const hrs = Math.floor(mins / 60)
  const remMins = Math.ceil(mins % 60)
  return `${hrs}h ${remMins}m remaining`
}

function formatSpeed(bps: number | null): string {
  if (bps === null || bps <= 0) return ''
  return `${formatBytes(bps)}/s`
}

export function DownloadProgressUI({ progress, onCancel, onRetry }: DownloadProgressUIProps) {
  const { state, percent, bytesDone, bytesTotal, etaSeconds, bytesPerSecond, error } = progress
  const pct = Math.min(100, Math.max(0, percent))

  if (state === 'error') {
    return (
      <div data-testid="download-error" style={containerStyle}>
        <span style={{ color: 'var(--error)' }}>✗ Download error: {error}</span>
      </div>
    )
  }

  if (state === 'done') {
    return (
      <div data-testid="download-done" style={containerStyle}>
        <span style={{ color: 'var(--success)' }}>✓ Download complete ({formatBytes(bytesTotal)})</span>
      </div>
    )
  }

  if (state === 'partial-stop') {
    return (
      <div data-testid="download-partial" style={containerStyle}>
        <span style={{ color: 'var(--warning)' }}>
          ⚠ Partial download saved as .partial ({formatBytes(bytesDone)} of {formatBytes(bytesTotal)})
        </span>
      </div>
    )
  }

  if (state === 'cancelled') {
    return (
      <div data-testid="download-cancelled" style={containerStyle}>
        <span>Download cancelled ({formatBytes(bytesDone)} downloaded)</span>
      </div>
    )
  }

  if (state === 'interrupted') {
    return (
      <div data-testid="download-interrupted" style={containerStyle}>
        <span style={{ color: 'var(--warning)' }}>⚠ Network error — {error}</span>
        <div style={{ display: 'flex', gap: 8, marginTop: 8 }}>
          <button onClick={onRetry} data-testid="download-retry-btn" style={btnStyle}>
            Retry
          </button>
          <button onClick={onCancel} data-testid="download-cancel-btn" style={btnStyle}>
            Cancel
          </button>
        </div>
      </div>
    )
  }

  // Fetching / verifying — split status across two lines
  const line1 = `${formatBytes(bytesDone)} / ${formatBytes(bytesTotal)}`
  const speedText = formatSpeed(bytesPerSecond)
  const etaText = formatEta(etaSeconds)

  return (
    <div data-testid="download-progress" style={containerStyle}>
      <div
        role="progressbar"
        aria-valuenow={pct}
        aria-valuemin={0}
        aria-valuemax={100}
        aria-valuetext={`${pct}%`}
        style={{
          width: '100%', height: 8, borderRadius: 4,
          background: 'var(--border)', overflow: 'hidden',
        }}
      >
        <div
          style={{
            width: `${pct}%`, height: '100%',
            background: 'var(--accent)', transition: 'width 0.15s ease-out',
          }}
        />
      </div>
      {/* Line 1: bytes downloaded / total · speed */}
      <div style={{ fontSize: '0.85em', color: 'var(--text-muted)', marginTop: 4 }}>
        {line1}{speedText ? ` · ${speedText}` : ''}
      </div>
      {/* Line 2: percentage · ETA */}
      <div style={{ display: 'flex', justifyContent: 'space-between', fontSize: '0.85em', color: 'var(--text-muted)', marginTop: 2 }}>
        <span>{pct}%</span>
        <span>{etaText}</span>
      </div>
      <div style={{ marginTop: 4 }}>
        <button onClick={onCancel} data-testid="download-cancel-btn" style={btnStyle}>
          Cancel
        </button>
      </div>
      <div role="status" aria-live="polite" style={{ position: 'absolute', left: -9999 }}>
        {pct === 0 ? 'Download started' : undefined}
        {pct === 25 ? '25% complete' : undefined}
        {pct === 50 ? '50% complete' : undefined}
        {pct === 75 ? '75% complete' : undefined}
      </div>
    </div>
  )
}

const containerStyle: React.CSSProperties = {
  padding: '8px 12px', borderRadius: 4,
  background: 'var(--surface)', border: '1px solid var(--border)',
}

const btnStyle: React.CSSProperties = {
  padding: '4px 12px', borderRadius: 4, cursor: 'pointer',
  border: '1px solid var(--border)', background: 'var(--surface)',
  fontSize: '0.9em',
}
