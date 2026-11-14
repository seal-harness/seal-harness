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

export function DownloadProgressUI({ progress, onCancel, onRetry }: DownloadProgressUIProps) {
  const { state, chunksDone, chunksTotal, bytesDone, bytesTotal, error } = progress
  const pct = chunksTotal > 0 ? Math.round((chunksDone / chunksTotal) * 100) : 0
  const valuetext = `${chunksDone} of ${chunksTotal} chunks, ${formatBytes(bytesDone)} of ${formatBytes(bytesTotal)}`

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
          ⚠ Partial download: {chunksDone} of {chunksTotal} chunks saved as .partial
        </span>
      </div>
    )
  }

  if (state === 'cancelled') {
    return (
      <div data-testid="download-cancelled" style={containerStyle}>
        <span>Download cancelled — {chunksDone} of {chunksTotal} chunks retained</span>
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

  // Fetching / verifying
  return (
    <div data-testid="download-progress" style={containerStyle}>
      <div
        role="progressbar"
        aria-valuenow={chunksDone}
        aria-valuemin={0}
        aria-valuemax={chunksTotal}
        aria-valuetext={valuetext}
        style={{
          width: '100%', height: 8, borderRadius: 4,
          background: 'var(--border)', overflow: 'hidden',
        }}
      >
        <div
          style={{
            width: `${pct}%`, height: '100%',
            background: 'var(--accent)', transition: 'width 0.2s ease',
          }}
        />
      </div>
      <div style={{ display: 'flex', justifyContent: 'space-between', marginTop: 4 }}>
        <span>{valuetext}</span>
        <button onClick={onCancel} data-testid="download-cancel-btn" style={btnStyle}>
          Cancel
        </button>
      </div>
      <div role="status" aria-live="polite" style={{ position: 'absolute', left: -9999 }}>
        {(state === 'fetching' || state === 'verifying') && pct === 0 ? 'Download started' : undefined}
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
