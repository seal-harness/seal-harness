import { useState, useEffect, useCallback } from 'react'
import type { FileEntry, FileListing, FileContent } from '../types'
import { useFileListing, useFileContent, downloadFile } from '../hooks/useApi'

// ── URL helpers ─────────────────────────────────────────────────────────

/** Read the `path` query parameter from the current URL. Returns null when
 *  absent (the backend then defaults to $HOME). */
function pathFromQuery(): string | null {
  if (typeof window === 'undefined') return null
  const params = new URLSearchParams(window.location.search)
  return params.get('path')
}

/** Read the `view` query parameter — 'content' means show the file content
 *  view; anything else (including absent) means directory listing. */
function viewFromQuery(): 'content' | null {
  if (typeof window === 'undefined') return null
  const params = new URLSearchParams(window.location.search)
  return params.get('view') === 'content' ? 'content' : null
}

/** Navigate to a new file-explorer URL by updating the query params and
 *  using pushState. The component re-reads the URL via its state effect. */
function navigateTo(path: string | null, view: 'content' | null = null) {
  const params = new URLSearchParams()
  if (path) params.set('path', path)
  if (view) params.set('view', view)
  const qs = params.toString()
  const url = qs ? `/files?${qs}` : '/files'
  window.history.pushState(null, '', url)
  window.dispatchEvent(new PopStateEvent('popstate'))
}

// ── Breadcrumbs ─────────────────────────────────────────────────────────

/** Split an absolute path into segments for the breadcrumb bar.
 *  `/home/user` → `[{ label: '/', path: '/' }, { label: 'home', path: '/home' }, { label: 'user', path: '/home/user' }]` */
function breadcrumbSegments(path: string): { label: string; path: string }[] {
  if (!path || path === '/') return [{ label: '/', path: '/' }]
  const parts = path.split('/').filter(Boolean)
  const segs: { label: string; path: string }[] = [{ label: '/', path: '/' }]
  let acc = ''
  for (const p of parts) {
    acc += '/' + p
    segs.push({ label: p, path: acc })
  }
  return segs
}

// ── Sorting ─────────────────────────────────────────────────────────────

/** Sort entries: directories first, then files. Within each group,
 *  alphabetical by name. Symlinks to directories are treated as
 *  directories (isDir is set by the backend). */
function sortEntries(entries: FileEntry[]): FileEntry[] {
  return [...entries].sort((a, b) => {
    if (a.isDir !== b.isDir) return a.isDir ? -1 : 1
    return a.name.localeCompare(b.name)
  })
}

// ── Formatting ──────────────────────────────────────────────────────────

function formatSize(size: number | null): string {
  if (size === null) return '—'
  if (size < 1024) return `${size} B`
  if (size < 1024 * 1024) return `${(size / 1024).toFixed(1)} KB`
  if (size < 1024 * 1024 * 1024) return `${(size / (1024 * 1024)).toFixed(1)} MB`
  return `${(size / (1024 * 1024 * 1024)).toFixed(1)} GB`
}

function formatMtime(mtime: string | null): string {
  if (!mtime) return '—'
  try {
    const d = new Date(mtime)
    return d.toLocaleString()
  } catch {
    return mtime
  }
}

/** Derive the parent directory of a file path for the Back button. */
function parentDir(filePath: string): string {
  const idx = filePath.lastIndexOf('/')
  if (idx <= 0) return '/'
  return filePath.slice(0, idx)
}

// ── Styles ──────────────────────────────────────────────────────────────

const sectionStyle: React.CSSProperties = {
  flex: 1,
  minHeight: 0,
  overflowY: 'auto',
  background: 'var(--bg-base)',
}

const headerStyle: React.CSSProperties = {
  padding: '12px 16px',
  borderBottom: '1px solid var(--border)',
  display: 'flex',
  alignItems: 'center',
  gap: 8,
  flexWrap: 'wrap',
}

const entryRowStyle: React.CSSProperties = {
  display: 'grid',
  gridTemplateColumns: '24px 1fr 100px 160px auto',
  alignItems: 'center',
  gap: 12,
  padding: '6px 16px',
  borderBottom: '1px solid var(--border-subtle, var(--border))',
  fontSize: 14,
  color: 'var(--text-primary)',
}

const linkStyle: React.CSSProperties = {
  cursor: 'pointer',
  color: 'var(--accent, #4a9eff)',
  textDecoration: 'none',
  background: 'none',
  border: 'none',
  padding: 0,
  font: 'inherit',
}

const buttonStyle: React.CSSProperties = {
  fontSize: 12,
  padding: '3px 8px',
  borderRadius: 'var(--radius-sm)',
  border: '1px solid var(--border)',
  background: 'var(--bg-elevated)',
  color: 'var(--text-primary)',
  cursor: 'pointer',
}

const bannerStyle: React.CSSProperties = {
  padding: '8px 16px',
  fontSize: 13,
  background: 'var(--bg-sunken)',
  borderBottom: '1px solid var(--border)',
}

// ── Banner components ───────────────────────────────────────────────────

function WarningBanner({ warning }: { warning: string }) {
  return (
    <div data-testid="warning-banner" style={{ ...bannerStyle, color: 'var(--text-warning, #c47b00)' }}>
      ⚠ {warning}
    </div>
  )
}

function TruncationIndicator({ testId, label }: { testId: string; label: string }) {
  return (
    <div data-testid={testId} style={{ ...bannerStyle, color: 'var(--text-faint)' }}>
      {label}
    </div>
  )
}

// ── Error message ───────────────────────────────────────────────────────

function errorMessageForStatus(status: number): string {
  switch (status) {
    case 404: return 'Path not found'
    case 403: return 'File explorer is disabled or access is forbidden'
    case 400: return 'Bad request — invalid path'
    case 0:   return 'Network error — could not reach the server'
    default:  return `Error (HTTP ${status})`
  }
}

function ErrorState({ status }: { status: number }) {
  return (
    <div data-testid="files-error" style={{ padding: 24, color: 'var(--text-danger, #d44)' }}>
      {errorMessageForStatus(status)}
    </div>
  )
}

function LoadingState() {
  return (
    <div data-testid="files-loading" style={{ padding: 24, color: 'var(--text-muted)' }}>
      <span className="animate-spin" style={{ display: 'inline-block', marginRight: 8 }}>◌</span>
      Loading…
    </div>
  )
}

// ── Breadcrumb bar ──────────────────────────────────────────────────────

function Breadcrumbs({ path }: { path: string }) {
  const segs = breadcrumbSegments(path)
  return (
    <div style={headerStyle} data-testid="breadcrumbs">
      {segs.map((seg, i) => (
        <span key={seg.path} style={{ display: 'inline-flex', alignItems: 'center', gap: 4 }}>
          {i > 0 && <span style={{ color: 'var(--text-faint)' }}>/</span>}
          <button
            type="button"
            style={linkStyle}
            data-testid={`breadcrumb-${seg.path}`}
            onClick={() => navigateTo(seg.path)}
          >
            {seg.label}
          </button>
        </span>
      ))}
    </div>
  )
}

// ── Directory listing ───────────────────────────────────────────────────

function DirectoryListing({
  listing,
  onNavigate,
}: {
  listing: FileListing
  onNavigate: (path: string | null, view?: 'content' | null) => void
}) {
  const [downloadTruncated, setDownloadTruncated] = useState(false)
  const sorted = sortEntries(listing.entries)
  return (
    <div>
      {listing.warning && <WarningBanner warning={listing.warning} />}
      {listing.truncated && (
        <TruncationIndicator testId="listing-truncated" label="⚠ Listing truncated — too many entries to show" />
      )}
      {downloadTruncated && (
        <div data-testid="download-truncated-warning" style={{ padding: '8px 16px', color: 'var(--text-warning, #c48017)' }}>
          ⚠ Last download was truncated — only the first 128 KiB was saved
        </div>
      )}
      <div>
        {sorted.map((entry) => {
          const fullPath = listing.path === '/' ? `/${entry.name}` : `${listing.path}/${entry.name}`
          return (
            <div
              key={entry.name}
              data-testid={`file-entry-${entry.name}`}
              onClick={entry.isDir ? () => onNavigate(fullPath) : undefined}
              style={entry.isDir ? { ...entryRowStyle, cursor: 'pointer' } : entryRowStyle}
            >
              <span style={{ color: 'var(--text-faint)' }}>
                {entry.isDir ? '📁' : entry.isSymlink ? '↪' : '📄'}
              </span>
              {entry.isDir ? (
                <button
                  type="button"
                  style={linkStyle}
                  onClick={() => onNavigate(fullPath)}
                >
                  {entry.name}
                </button>
              ) : (
                <span>{entry.name}</span>
              )}
              <span style={{ color: 'var(--text-faint)', fontSize: 12 }}>
                {formatSize(entry.size)}
              </span>
              <span style={{ color: 'var(--text-faint)', fontSize: 12 }}>
                {formatMtime(entry.mtime)}
              </span>
              {!entry.isDir && (
                <span style={{ display: 'inline-flex', gap: 8 }}>
                  <button
                    type="button"
                    style={buttonStyle}
                    data-testid={`view-${entry.name}`}
                    onClick={() => onNavigate(fullPath, 'content')}
                  >
                    View
                  </button>
                  <button
                    type="button"
                    style={buttonStyle}
                    data-testid={`download-${entry.name}`}
                    onClick={async () => {
                      const result = await downloadFile(fullPath)
                      setDownloadTruncated(result.truncated)
                    }}
                  >
                    Download
                  </button>
                </span>
              )}
            </div>
          )
        })}
        {sorted.length === 0 && (
          <div style={{ padding: 24, color: 'var(--text-muted)' }}>This directory is empty.</div>
        )}
      </div>
    </div>
  )
}

// ── File content view ───────────────────────────────────────────────────

function FileContentView({
  content,
  onBack,
}: {
  content: FileContent
  onBack: () => void
}) {
  const [truncationWarning, setTruncationWarning] = useState(false)

  const handleDownload = useCallback(async () => {
    const result = await downloadFile(content.path)
    if (result.truncated) {
      setTruncationWarning(true)
    } else {
      setTruncationWarning(false)
    }
  }, [content.path])

  return (
    <div>
      {content.truncated && (
        <TruncationIndicator
          testId="content-truncated"
          label={`⚠ Content truncated — showing ${content.linesRead} lines (file exceeds the size limit)`}
        />
      )}
      {truncationWarning && (
        <div
          data-testid="download-truncation-warning"
          style={{ ...bannerStyle, color: 'var(--text-warning, #c47b00)' }}
        >
          ⚠ Download was truncated — the file exceeds the server's byte limit. The downloaded file is incomplete.
        </div>
      )}
      <div style={{ padding: '8px 16px', display: 'flex', gap: 12, borderBottom: '1px solid var(--border)' }}>
        <button type="button" style={buttonStyle} data-testid="content-download" onClick={handleDownload}>
          Download
        </button>
        <button type="button" style={buttonStyle} data-testid="content-back" onClick={onBack}>
          Back to directory
        </button>
      </div>
      {content.isBinary ? (
        <div
          data-testid="binary-file-message"
          style={{ padding: 24, color: 'var(--text-muted)' }}
        >
          This is a binary file. Use the Download button to save it.
        </div>
      ) : (
        <pre
          data-testid="file-content-pre"
          style={{
            padding: 16,
            margin: 0,
            fontFamily: 'var(--font-mono)',
            fontSize: 13,
            lineHeight: 1.5,
            color: 'var(--text-primary)',
            whiteSpace: 'pre-wrap',
            wordBreak: 'break-all',
            overflowWrap: 'anywhere',
          }}
        >
          {content.content}
        </pre>
      )}
    </div>
  )
}

// ── Main component ──────────────────────────────────────────────────────

export function FilesView() {
  const [path, setPath] = useState<string | null>(pathFromQuery())
  const [view, setView] = useState<'content' | null>(viewFromQuery())

  // Re-read URL state on popstate (back/forward + our own navigateTo).
  useEffect(() => {
    const onPop = () => {
      setPath(pathFromQuery())
      setView(viewFromQuery())
    }
    window.addEventListener('popstate', onPop)
    return () => window.removeEventListener('popstate', onPop)
  }, [])

  const onNavigate = useCallback((newPath: string | null, newView: 'content' | null = null) => {
    navigateTo(newPath, newView)
  }, [])

  // Listing mode
  const listingResult = useFileListing(view === 'content' ? null : path)
  // Content mode
  const contentResult = useFileContent(view === 'content' ? path : null)

  // The effective path for breadcrumbs: in content mode, the file path;
  // in listing mode, the listing's resolved path (or the query path).
  const breadcrumbPath = view === 'content'
    ? (path ?? '')
    : (listingResult.listing?.path ?? path ?? '/')

  return (
    <div style={sectionStyle}>
      <Breadcrumbs path={breadcrumbPath} />
      {view === 'content' ? (
        contentResult.loading ? (
          <LoadingState />
        ) : contentResult.error !== null ? (
          <ErrorState status={contentResult.error} />
        ) : contentResult.content ? (
          <FileContentView
            content={contentResult.content}
            onBack={() => onNavigate(parentDir(contentResult.content!.path))}
          />
        ) : null
      ) : (
        listingResult.loading ? (
          <LoadingState />
        ) : listingResult.error !== null ? (
          <ErrorState status={listingResult.error} />
        ) : listingResult.listing ? (
          <DirectoryListing listing={listingResult.listing} onNavigate={onNavigate} />
        ) : null
      )}
    </div>
  )
}
