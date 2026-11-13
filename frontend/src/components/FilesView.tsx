import { useState, useEffect, useCallback, useRef } from 'react'
import type { FileEntry, FileListing, FileContent } from '../types'
import { fetchFileListing, fetchFileContent, downloadFile } from '../hooks/useApi'
import { FileTree, type FileTreeNode } from './FileTree'

// ── URL helpers ─────────────────────────────────────────────────────────

/** Read the `path` query parameter. Absent ⇒ the backend resolves $HOME. */
function pathFromQuery(): string | null {
  if (typeof window === 'undefined') return null
  return new URLSearchParams(window.location.search).get('path')
}

/** Navigate to a file-explorer URL via pushState. */
function navigateTo(path: string | null) {
  const params = new URLSearchParams()
  if (path) params.set('path', path)
  const qs = params.toString()
  window.history.pushState(null, '', qs ? `/files?${qs}` : '/files')
  window.dispatchEvent(new PopStateEvent('popstate'))
}

// ── Paths ───────────────────────────────────────────────────────────────

/** Parent directory of a path. `/a/b` → `/a`; `/a` → `/`; `/` → `/`. */
function parentDir(path: string): string {
  if (!path || path === '/') return '/'
  const idx = path.lastIndexOf('/')
  if (idx <= 0) return '/'
  return path.slice(0, idx)
}

/** Basename of a path. */
function basename(path: string): string {
  if (!path || path === '/') return '/'
  const idx = path.lastIndexOf('/')
  return idx < 0 ? path : path.slice(idx + 1)
}

function joinPath(dir: string, name: string): string {
  return dir === '/' ? `/${name}` : `${dir}/${name}`
}

/** Breadcrumb segments. Deep paths collapse the middle to `…`. */
function breadcrumbSegments(path: string): { label: string; path: string; ellipsis?: boolean }[] {
  if (!path || path === '/') return [{ label: '/', path: '/' }]
  const parts = path.split('/').filter(Boolean)
  const segs: { label: string; path: string; ellipsis?: boolean }[] = [{ label: '/', path: '/' }]
  const MAX = 5
  const collapse = parts.length > MAX
  let acc = ''
  parts.forEach((p, i) => {
    acc += '/' + p
    if (collapse && i >= 1 && i < parts.length - 1) {
      // emit a single ellipsis marker in place of the collapsed middle
      if (i === 1) segs.push({ label: '…', path: acc, ellipsis: true })
      return
    }
    segs.push({ label: p, path: acc })
  })
  return segs
}

/** Sort: directories first, then files, alphabetical within each group. */
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
    return new Date(mtime).toLocaleString()
  } catch {
    return mtime
  }
}

function errorMessageForStatus(status: number): string {
  switch (status) {
    case 404: return 'Path not found'
    case 403: return 'File explorer is disabled or access is forbidden'
    case 400: return 'Bad request — invalid path'
    case 0: return 'Network error — could not reach the server'
    default: return `Error (HTTP ${status})`
  }
}

// ── Shared style fragments ──────────────────────────────────────────────

const sectionStyle: React.CSSProperties = {
  display: 'flex',
  flex: 1,
  minHeight: 0,
  background: 'var(--bg-base)',
}

const railStyle: React.CSSProperties = {
  width: 280,
  flexShrink: 0,
  display: 'flex',
  flexDirection: 'column',
  background: 'var(--bg-surface)',
  borderRight: '1px solid var(--border)',
}

const railHeaderStyle: React.CSSProperties = {
  display: 'flex',
  alignItems: 'center',
  justifyContent: 'space-between',
  padding: '8px 12px',
  borderBottom: '1px solid var(--border)',
}

const railTitleStyle: React.CSSProperties = {
  fontSize: 11,
  fontWeight: 600,
  textTransform: 'uppercase',
  letterSpacing: '0.08em',
  color: 'var(--text-muted)',
}

const headerStyle: React.CSSProperties = {
  padding: '8px 16px',
  borderBottom: '1px solid var(--border)',
  display: 'flex',
  alignItems: 'center',
  gap: 8,
  flexWrap: 'wrap',
}

const linkStyle: React.CSSProperties = {
  cursor: 'pointer',
  color: 'var(--accent-secondary)',
  textDecoration: 'none',
  background: 'none',
  border: 'none',
  padding: 0,
  font: 'inherit',
}

const bannerStyle: React.CSSProperties = {
  display: 'flex',
  alignItems: 'center',
  gap: 8,
  background: 'var(--bg-elevated)',
  border: '1px solid var(--border)',
  borderRadius: 'var(--radius-sm)',
  padding: '8px 12px',
  margin: '8px 16px',
  fontSize: 13,
  color: 'var(--text-muted)',
}

const rowStyle: React.CSSProperties = {
  display: 'flex',
  alignItems: 'center',
  gap: 12,
  width: '100%',
  padding: '6px 16px',
  borderBottom: '1px solid var(--border)',
  background: 'none',
  border: 'none',
  borderBottomWidth: 1,
  borderBottomStyle: 'solid',
  borderBottomColor: 'var(--border)',
  textAlign: 'left',
  fontSize: 14,
  color: 'var(--text-primary)',
  font: 'inherit',
  cursor: 'pointer',
}

// ── Sub-components ──────────────────────────────────────────────────────

function Breadcrumbs({ path }: { path: string }) {
  const segs = breadcrumbSegments(path)
  return (
    <div style={headerStyle} data-testid="breadcrumbs">
      {segs.map((seg, i) => (
        <span key={`${seg.path}-${i}`} style={{ display: 'inline-flex', alignItems: 'center', gap: 4 }}>
          {i > 0 && <span style={{ color: 'var(--text-faint)' }}>/</span>}
          {seg.ellipsis ? (
            <span data-testid="breadcrumb-ellipsis" style={{ color: 'var(--text-faint)' }}>
              {seg.label}
            </span>
          ) : (
            <button
              type="button"
              style={linkStyle}
              data-testid={`breadcrumb-${seg.path}`}
              onClick={() => navigateTo(seg.path)}
            >
              {seg.label}
            </button>
          )}
        </span>
      ))}
    </div>
  )
}

function LoadingState() {
  return (
    <div data-testid="files-loading" style={{ padding: 24, color: 'var(--text-muted)' }}>
      Loading…
    </div>
  )
}

function ErrorState({ status }: { status: number }) {
  return (
    <div data-testid="files-error" style={{ padding: 24, color: 'var(--needs-input)' }}>
      {errorMessageForStatus(status)}
    </div>
  )
}

function DirectoryListing({
  listing,
  onOpen,
  onDownload,
  downloadTruncated,
}: {
  listing: FileListing
  onOpen: (entry: FileEntry) => void
  onDownload: (entry: FileEntry) => void
  downloadTruncated: boolean
}) {
  const sorted = sortEntries(listing.entries)
  return (
    <div>
      {listing.warning && (
        <div data-testid="warning-banner" style={bannerStyle}>
          <span style={{ color: 'var(--warning)' }}>⚠</span>
          <span>{listing.warning}</span>
        </div>
      )}
      {listing.truncated && (
        <div data-testid="listing-truncated" style={{ ...bannerStyle, color: 'var(--text-faint)' }}>
          ⚠ Listing truncated — too many entries to show
        </div>
      )}
      {downloadTruncated && (
        <div data-testid="download-truncated-warning" style={{ ...bannerStyle, color: 'var(--warning)' }}>
          ⚠ Last download was truncated — only the first 128 KiB was saved
        </div>
      )}
      {sorted.length === 0 ? (
        <div data-testid="empty-directory" style={{ padding: 24, color: 'var(--text-muted)' }}>
          This directory is empty.
        </div>
      ) : (
        sorted.map((entry) => (
          <FileRow key={entry.name} entry={entry} listing={listing} onOpen={onOpen} onDownload={onDownload} />
        ))
      )}
    </div>
  )
}

function FileRow({
  entry,
  listing,
  onOpen,
  onDownload,
}: {
  entry: FileEntry
  listing: FileListing
  onOpen: (entry: FileEntry) => void
  onDownload: (entry: FileEntry) => void
}) {
  const fullPath = joinPath(listing.path, entry.name)
  return (
    <div style={{ display: 'flex', alignItems: 'center' }}>
      <button
        type="button"
        data-testid={`file-entry-${entry.name}`}
        className="files-row"
        aria-label={`${entry.isDir ? 'Open directory' : 'Open file'} ${entry.name}`}
        style={{ ...rowStyle, borderBottom: 'none', flex: 1 }}
        onClick={() => onOpen(entry)}
      >
        <span style={{ color: 'var(--text-faint)', width: 14, display: 'inline-flex' }}>
          {entry.isDir || entry.isSymlink ? (
            <svg width="11" height="11" viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
              <path d="M2 13 V4 a1 1 0 0 1 1 -1 h3 l1.5 2 H13 a1 1 0 0 1 1 1 v7 a1 1 0 0 1 -1 1 H3 a1 1 0 0 1 -1 -1 Z" />
            </svg>
          ) : (
            <svg width="11" height="11" viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
              <path d="M4 1 h5 l3 3 v11 a1 1 0 0 1 -1 1 H4 a1 1 0 0 1 -1 -1 V2 a1 1 0 0 1 1 -1 Z" />
              <path d="M9 1 v3 h3" />
            </svg>
          )}
        </span>
        <span style={{ flex: 1 }}>{entry.name}</span>
        <span style={{ color: 'var(--text-faint)', fontSize: 12, width: 80 }}>
          {formatSize(entry.size)}
        </span>
        <span style={{ color: 'var(--text-faint)', fontSize: 12, width: 160 }}>
          {formatMtime(entry.mtime)}
        </span>
      </button>
      {!entry.isDir && (
        <button
          type="button"
          className="icon-btn"
          data-testid={`download-${entry.name}`}
          aria-label={`Download ${entry.name}`}
          title={`Download ${entry.name}`}
          style={{ marginRight: 12 }}
          onClick={(e) => {
            e.stopPropagation()
            onDownload(entry)
          }}
        >
          <svg width="11" height="11" viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
            <path d="M8 2 v8" />
            <path d="M4.5 7 L8 10.5 L11.5 7" />
            <path d="M3 13 h10" />
          </svg>
        </button>
      )}
      <span style={{ display: 'none' }}>{fullPath}</span>
    </div>
  )
}

function FileContentView({
  content,
  onBack,
  onDownload,
  downloadTruncated,
}: {
  content: FileContent
  onBack: () => void
  onDownload: () => void
  downloadTruncated: boolean
}) {
  return (
    <div>
      {content.truncated && (
        <div data-testid="content-truncated" style={{ ...bannerStyle, color: 'var(--text-faint)' }}>
          ⚠ Content truncated — showing {content.linesRead} lines
        </div>
      )}
      {downloadTruncated && (
        <div
          data-testid="viewer-download-truncated-warning"
          style={{ ...bannerStyle, color: 'var(--warning)' }}
        >
          ⚠ Download was truncated — the file exceeds the server's byte limit.
        </div>
      )}
      <div style={{ ...headerStyle }}>
        <button type="button" className="btn btn-ghost" data-testid="content-download" style={{ fontSize: 12, padding: '3px 8px' }} onClick={onDownload}>
          Download
        </button>
        <button type="button" className="btn btn-ghost" data-testid="content-back" style={{ fontSize: 12, padding: '3px 8px' }} onClick={onBack}>
          Back to directory
        </button>
      </div>
      {content.isBinary ? (
        <div data-testid="binary-file-message" style={{ padding: 24, color: 'var(--text-muted)' }}>
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
          }}
        >
          {content.content}
        </pre>
      )}
    </div>
  )
}

// ── Node tree construction ──────────────────────────────────────────────


// ── Main component ──────────────────────────────────────────────────────

export function FilesView() {
  const [path, setPath] = useState<string | null>(pathFromQuery)
  // Listings owned here, keyed by the *requested* path (null for the $HOME
  // request), so the rail and detail pane share one copy.
  const [listings, setListings] = useState<Map<string | null, FileListing>>(new Map())
  const [expanded, setExpanded] = useState<Set<string>>(new Set())
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<number | null>(null)
  const [content, setContent] = useState<FileContent | null>(null)
  const [contentLoading, setContentLoading] = useState(false)
  const [downloadTruncated, setDownloadTruncated] = useState(false)
  const [viewerDownloadTruncated, setViewerDownloadTruncated] = useState(false)
  const [railError, setRailError] = useState<Map<string, number>>(new Map())
  const inflight = useRef<Map<string | null, Promise<FileListing | null>>>(new Map())
  const statusRef = useRef<Map<string | null, number>>(new Map())
  // Mirror of `listings` for synchronous reads inside async flows: the resolve
  // effect closes over the render's `listings`, which is stale after a
  // setListings in the same tick.
  const listingsRef = useRef<Map<string | null, FileListing>>(new Map())

  useEffect(() => {
    const onPop = () => setPath(pathFromQuery())
    window.addEventListener('popstate', onPop)
    return () => window.removeEventListener('popstate', onPop)
  }, [])

  /** Fetch a listing, deduping concurrent requests for the same key.
   *  Returns the status too, so callers never read stale error state. */
  const loadListing = useCallback(
    async (
      key: string | null,
      force = false,
    ): Promise<{ listing: FileListing | null; status: number | null }> => {
      if (!force && listingsRef.current.has(key)) {
        return { listing: listingsRef.current.get(key)!, status: null }
      }
      const pending = inflight.current.get(key)
      if (!force && pending) return { listing: await pending, status: null }

      const p = fetchFileListing(key).then((res) => {
        inflight.current.delete(key)
        if (res.ok) {
          listingsRef.current.set(key, res.listing)
          setListings((prev) => new Map(prev).set(key, res.listing))
          setRailError((prev) => {
            if (!prev.has(key as string)) return prev
            const next = new Map(prev)
            next.delete(key as string)
            return next
          })
          statusRef.current.delete(key)
          return res.listing
        }
        setRailError((prev) => new Map(prev).set(key as string, res.status))
        statusRef.current.set(key, res.status)
        return null
      })
      inflight.current.set(key, p)
      const listing = await p
      return { listing, status: listing ? null : (statusRef.current.get(key) ?? 0) }
    },
    [],
  )

  // Resolve the main pane: derive the rail root, then decide listing vs viewer.
  useEffect(() => {
    let cancelled = false
    setLoading(true)
    setError(null)
    setContent(null)

    const run = async () => {
      const target = path
      const railRoot = target ? parentDir(target) : null
      const rootRes = await loadListing(railRoot)
      const rootListing = rootRes.listing
      if (cancelled) return
      if (!rootListing) {
        setError(rootRes.status ?? 404)
        setLoading(false)
        return
      }
      // Expand the ancestors of the target so it is visible in the rail.
      if (target && target !== '/') {
        const segs: string[] = []
        let acc = ''
        for (const p of target.split('/').filter(Boolean)) {
          acc += '/' + p
          segs.push(acc)
        }
        setExpanded((prev) => {
          const next = new Set(prev)
          segs.forEach((s) => next.add(s))
          return next
        })
      }

      if (!target || target === '/') {
        // Rail root IS the content: nothing more to resolve.
        setLoading(false)
        return
      }

      if (target === railRoot) {
        // A directory bookmark: the root listing is the content.
        setLoading(false)
        return
      }

      const name = basename(target)
      const entry = rootListing.entries.find((e) => e.name === name)
      if (entry) {
        if (entry.isDir) {
          const dirRes = await loadListing(target)
          if (cancelled) return
          if (!dirRes.listing) setError(dirRes.status ?? 404)
        } else {
          setContentLoading(true)
          const res = await fetchFileContent(target)
          if (cancelled) return
          setContentLoading(false)
          if (res.ok) setContent(res.content)
          else setError(res.status)
        }
        if (!cancelled) setLoading(false)
        return
      }

      // Probe-miss: the basename is absent from the parent listing (deleted
      // file, truncated listing, or a `|`-in-name drop). One content probe
      // resolves the kind: 200 file, 400 directory, 404 gone.
      setContentLoading(true)
      const probe = await fetchFileContent(target)
      if (cancelled) return
      if (probe.ok) {
        setContentLoading(false)
        setContent(probe.content)
        setLoading(false)
        return
      }
      if (probe.status === 400) {
        // It is a directory after all.
        await loadListing(target)
        setContentLoading(false)
        setLoading(false)
        return
      }
      setContentLoading(false)
      setError(probe.status)
      setLoading(false)
    }

    void run()
    return () => { cancelled = true }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [path])

  const onNavigate = useCallback((newPath: string | null) => navigateTo(newPath), [])

  const onToggle = useCallback(
    (nodePath: string) => {
      setExpanded((prev) => {
        const next = new Set(prev)
        if (next.has(nodePath)) next.delete(nodePath)
        else next.add(nodePath)
        return next
      })
      // Lazily load children on first expand.
      if (!listingsRef.current.has(nodePath)) void loadListing(nodePath)
    },
    [loadListing],
  )

  const onSelect = useCallback((nodePath: string) => navigateTo(nodePath), [])

  const onRetry = useCallback(
    (nodePath: string) => {
      void loadListing(nodePath, true)
    },
    [loadListing],
  )

  const handleOpen = useCallback(
    (entry: FileEntry) => {
      const listing = path === null
        ? listings.get(null)
        : listings.get(path) ?? listings.get(parentDir(path))
      const base = listing?.path ?? (path ?? '')
      const target = joinPath(base, entry.name)
      navigateTo(target)
    },
    [path, listings],
  )

  const doDownload = useCallback(async (target: string) => {
    const res = await downloadFile(target)
    return res.truncated
  }, [])

  const handleDownload = useCallback(
    async (entry: FileEntry) => {
      const listing = path === null
        ? listings.get(null)
        : listings.get(path) ?? listings.get(parentDir(path))
      const base = listing?.path ?? (path ?? '')
      setDownloadTruncated(await doDownload(joinPath(base, entry.name)))
    },
    [path, listings, doDownload],
  )

  const handleViewerDownload = useCallback(async () => {
    if (!content) return
    setViewerDownloadTruncated(await doDownload(content.path))
  }, [content, doDownload])

  // ── Derive the rail ────────────────────────────────────────────────────

  const railRoot = path ? parentDir(path) : null
  const rootListing = listings.get(railRoot)

  const buildNodes = (listing: FileListing): FileTreeNode[] =>
    sortEntries(listing.entries).map((e) => {
      const childPath = joinPath(listing.path, e.name)
      const isExpanded = expanded.has(childPath)
      const childListing = listings.get(childPath)
      const errStatus = railError.get(childPath)
      return {
        path: childPath,
        name: e.name,
        isDir: e.isDir,
        isSymlink: e.isSymlink,
        expanded: isExpanded,
        selected: path === childPath,
        status: errStatus !== undefined ? 'error' : isExpanded && !childListing ? 'loading' : 'idle',
        children: childListing ? buildNodes(childListing) : undefined,
      }
    })

  // The rail's top level is the parent of the rail root, so the root itself is
  // reachable; when the rail root is `/` there is no parent.
  const railNodes: FileTreeNode[] = rootListing ? buildNodes(rootListing) : []
  const railIsLoading = !rootListing && railRoot !== null

  // ── Derive the main pane ───────────────────────────────────────────────

  const isDirectoryTarget =
    path === null || path === '/' || path === railRoot || listings.has(path)
  const listingForPane: FileListing | undefined = path === null
    ? rootListing
    : listings.get(path) ?? (path === railRoot ? rootListing : undefined)

  return (
    <div style={sectionStyle}>
      <div style={railStyle}>
        <div style={railHeaderStyle}>
          <span style={railTitleStyle}>Files</span>
          <button
            type="button"
            className="btn btn-ghost"
            aria-label="Refresh"
            title="Refresh"
            style={{ width: 22, height: 22, padding: 0, fontSize: 13, lineHeight: 1 }}
            onClick={() => {
              listingsRef.current.clear()
              setListings(new Map())
              inflight.current.clear()
              setRailError(new Map())
              void loadListing(railRoot, true)
            }}
          >
            ⟳
          </button>
        </div>
        <div className="flex-1 overflow-y-auto sidebar-scroll">
          {railIsLoading && (
            <div className="px-3 py-2 text-xs" style={{ color: 'var(--text-faint)' }}>
              Loading…
            </div>
          )}
          {rootListing && (
            <FileTree
              nodes={railNodes}
              onToggle={onToggle}
              onSelect={onSelect}
              onRetry={onRetry}
            />
          )}
        </div>
      </div>

      <div className="flex-1 overflow-y-auto" style={{ minWidth: 0 }}>
        <Breadcrumbs path={path ?? rootListing?.path ?? '/'} />
        {loading || contentLoading ? (
          <LoadingState />
        ) : error !== null ? (
          <ErrorState status={error} />
        ) : content ? (
          <FileContentView
            content={content}
            onBack={() => onNavigate(parentDir(content.path))}
            onDownload={handleViewerDownload}
            downloadTruncated={viewerDownloadTruncated}
          />
        ) : listingForPane && isDirectoryTarget ? (
          <DirectoryListing
            listing={listingForPane}
            onOpen={handleOpen}
            onDownload={handleDownload}
            downloadTruncated={downloadTruncated}
          />
        ) : null}
      </div>
    </div>
  )
}
