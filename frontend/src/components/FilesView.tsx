import { useState, useEffect, useCallback, useRef } from 'react'
import type { FileEntry, FileListing, FileContent } from '../types'
import { fetchFileListing, fetchFileListingWithRail, fetchFileContent, fetchFileStat } from '../hooks/useApi'
import { useFileDownload } from '../hooks/useFileDownload'
import { DownloadProgressUI } from './DownloadProgress'
import { FileTree, type FileTreeNode } from './FileTree'
import { DownloadConfirmDialog } from './DownloadConfirmDialog'

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


/** The configured prompt threshold for downloads. In production this
 *  comes from the backend config; for now we use the default. */
const DOWNLOAD_PROMPT_THRESHOLD = 268435456 // 256 MiB

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

/** Every ancestor of a path, shortest first, always including `/`.
 *  `/home/user/readme.txt` → `['/', '/home', '/home/user']` */
function ancestorsOf(path: string): string[] {
  if (!path || path === '/') return ['/']
  const parts = path.split('/').filter(Boolean)
  const out: string[] = ['/']
  let acc = ''
  // strictly shorter than the path itself: the path's own parent is the last.
  for (let i = 0; i < parts.length - 1; i++) {
    acc += '/' + parts[i]
    out.push(acc)
  }
  // Ensure the immediate parent is present even for a direct child of `/`.
  const parent = parentDir(path)
  if (!out.includes(parent)) out.push(parent)
  return out
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

function Breadcrumbs({ path, children }: { path: string; children?: React.ReactNode }) {
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
      {children}
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
  showHidden,
}: {
  listing: FileListing
  onOpen: (entry: FileEntry) => void
  onDownload: (entry: FileEntry) => void
  downloadTruncated: boolean
  showHidden: boolean
}) {
  const filtered = showHidden ? listing.entries : listing.entries.filter(e => !e.name.startsWith('.'))
  const sorted = sortEntries(filtered)
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
          ⚠ Last download was truncated — the file exceeded the server's byte limit
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
        <a
          className="icon-btn"
          href={`/api/files/download?path=${encodeURIComponent(fullPath)}`}
          data-testid={`download-${entry.name}`}
          aria-label={`Download ${entry.name}`}
          title={`Download ${entry.name}`}
          style={{ marginRight: 12 }}
          onClick={(e) => {
            e.stopPropagation()
            e.preventDefault()
            onDownload(entry)
          }}
        >
          <svg width="11" height="11" viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
            <path d="M8 2 v8" />
            <path d="M4.5 7 L8 10.5 L11.5 7" />
            <path d="M3 13 h10" />
          </svg>
        </a>
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
        <a
          className="btn btn-ghost"
          href={`/api/files/download?path=${encodeURIComponent(content.path)}`}
          data-testid="content-download"
          style={{ fontSize: 12, padding: '3px 8px' }}
          onClick={(e) => { e.preventDefault(); onDownload() }}
        >
          Download
        </a>
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
  // Paths the user explicitly collapsed. Navigation ("sticky additions") may
  // only ADD to `expanded`; it must never re-open one of these, or a manual
  // collapse would be silently undone by the next click elsewhere.
  const [collapsedByUser, setCollapsedByUser] = useState<Set<string>>(new Set())
  const expandedRef = useRef<Set<string>>(new Set())
  expandedRef.current = expanded
  const collapsedRef = useRef<Set<string>>(new Set())
  collapsedRef.current = collapsedByUser
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<number | null>(null)
  const [content, setContent] = useState<FileContent | null>(null)
  const [contentLoading, setContentLoading] = useState(false)
  const [downloadTruncated] = useState(false)
  const [viewerDownloadTruncated] = useState(false)
  const [showHidden, setShowHidden] = useState(false)
  const [confirmDialog, setConfirmDialog] = useState<{ path: string; size: number } | null>(null)
  const fileDownload = useFileDownload()
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
  /** Resolve the main pane AND the rail chain for `target` in ONE request.
   *  Falls back to per-path loading if the batch comes back short (transport
   *  truncation), so correctness never depends on the optimization. */
  const loadWithRail = useCallback(
    async (
      target: string | null,
      railPaths: string[],
    ): Promise<{ listing: FileListing | null; status: number | null; railShort: string[] }> => {
      const res = await fetchFileListingWithRail(target, railPaths)
      if (!res.ok) {
        statusRef.current.set(target, res.status)
        return { listing: null, status: res.status, railShort: [] }
      }
      listingsRef.current.set(target, res.listing)
      setListings((prev) => new Map(prev).set(target, res.listing))
      const got = new Set<string>()
      res.rail.forEach((l) => {
        listingsRef.current.set(l.path, l)
        got.add(l.path)
      })
      if (res.rail.length > 0) {
        setListings((prev) => {
          const next = new Map(prev)
          res.rail.forEach((l) => next.set(l.path, l))
          return next
        })
      }
      return {
        listing: res.listing,
        status: null,
        railShort: railPaths.filter((p) => !got.has(p)),
      }
    },
    [],
  )

  // ── Rail seed: ONCE, at the filesystem root ───────────────────────────
  //
  // The rail is rooted at `/` and only ever changes from direct user action
  // (expand/collapse). Navigating up or down changes the main pane only.
  // This effect therefore depends on nothing.
  const [railReady, setRailReady] = useState(false)
  const seedDone = useRef<Promise<void>>(Promise.resolve())
  // Bumped by the refresh button; forces both resolve effects to re-run.
  const [refreshTick, setRefreshTick] = useState(0)
  useEffect(() => {
    let cancelled = false
    seedDone.current = (async () => {
      // Seed '/' together with the ancestor chain of the current path in ONE
      // batched call, so a cold deep link costs that call plus the content.
      const initial = pathFromQuery()
      // Include the target itself for directories: the pane's listing is then
      // part of the same batched call, so a cold directory view is ONE request.
      // Ancestors only: `initial` may be a file, and asking the listing
      // endpoint for a file is a 400 that would fail the whole batch.
      const chain = initial ? ancestorsOf(initial).filter((a) => a !== '/') : []
      const res = await fetchFileListingWithRail('/', chain)
      if (cancelled) return
      if (!res.ok) {
        setRailError(new Map([['/', res.status]]))
        setRailReady(true)
        return
      }
      listingsRef.current.set('/', res.listing)
      res.rail.forEach((l) => listingsRef.current.set(l.path, l))
      setListings(() => {
        const next = new Map<string | null, FileListing>()
        next.set('/', res.listing)
        res.rail.forEach((l) => next.set(l.path, l))
        return next
      })
      setRailReady(true)
    })()
    return () => { cancelled = true }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  // ── Rail expansion for the current path ───────────────────────────────
  //
  // Sticky additions: expand the ancestors of the *current* path so it is
  // visible, never collapsing anything and never re-opening a node the user
  // explicitly collapsed. No fetching happens here — the batched seed/pane
  // calls already populate the cache.
  useEffect(() => {
    if (!railReady || !path) return
    const chain = ancestorsOf(path)
    setExpanded((prev) => {
      const next = new Set(prev)
      chain.forEach((a) => { if (!collapsedRef.current.has(a)) next.add(a) })
      return next
    })
  }, [path, railReady, refreshTick])

  // ── Main pane resolution (per navigation) ─────────────────────────────
  useEffect(() => {
    if (!railReady) return
    let cancelled = false
    setLoading(true)
    setError(null)
    setContent(null)

    const run = async () => {
      // The rail seed populates the listing cache for the whole ancestor
      // chain; waiting for it means a cold deep link needs no extra request.
      await seedDone.current
      if (cancelled) return
      const target = path

      if (!target) {
        // No `path`: the main pane shows the resolved $HOME listing (the
        // backend defaults it). The rail is independent and stays at `/`.
        await loadListing(null)
        if (!cancelled) setLoading(false)
        return
      }

      if (target === '/') {
        if (!cancelled) setLoading(false)
        return
      }

      const parent = parentDir(target)
      // The rail seed batches the whole ancestor chain; wait for it so a cold
      // deep link needs no second request.
      await seedDone.current
      if (cancelled) return
      const cached = listingsRef.current.get(parent)
      const batch = cached
        ? { listing: cached, status: null, railShort: [] as string[] }
        : await loadWithRail(
            parent,
            ancestorsOf(target).filter((a) => a !== parent),
          )
      if (cancelled) return
      const parentListing = batch.listing
      if (!parentListing) {
        setError(batch.status ?? 404)
        setLoading(false)
        return
      }
      // Truncated batch: fetch the missing ancestors the slow way.
      if (batch.railShort.length > 0) {
        await Promise.all(batch.railShort.map((p) => loadListing(p)))
        if (cancelled) return
      }

      const name = basename(target)
      const entry = parentListing.entries.find((e) => e.name === name)

      if (entry) {
        if (entry.isDir) {
          // The seed's batched call normally already fetched this directory;
          // loadListing only reaches the network on a miss.
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
  }, [path, railReady, refreshTick])

  const onNavigate = useCallback((newPath: string | null) => navigateTo(newPath), [])

  const onToggle = useCallback(
    (nodePath: string) => {
      const isExpanded = expandedRef.current.has(nodePath)
      const nextExpanded = !isExpanded

      setExpanded((prev) => {
        const next = new Set(prev)
        if (nextExpanded) next.add(nodePath)
        else next.delete(nodePath)
        return next
      })

      // Record the manual intent: a collapse must survive navigation
      // ("sticky additions" only ever adds), and a re-expand clears the mark.
      setCollapsedByUser((prev) => {
        const next = new Set(prev)
        if (nextExpanded) next.delete(nodePath)
        else next.add(nodePath)
        return next
      })

      // Lazily load children on first expand.
      if (nextExpanded && !listingsRef.current.has(nodePath)) void loadListing(nodePath)
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

  const handleDownload = useCallback(
    async (entry: FileEntry) => {
      const listing = path === null
        ? listings.get(null)
        : listings.get(path) ?? listings.get(parentDir(path))
      const base = listing?.path ?? (path ?? '')
      const target = joinPath(base, entry.name)
      // Fetch stat first; if over threshold, show confirm dialog.
      const statRes = await fetchFileStat(target)
      if (statRes.ok && statRes.stat.size > DOWNLOAD_PROMPT_THRESHOLD) {
        setConfirmDialog({ path: target, size: statRes.stat.size })
      } else {
        void fileDownload.start(target)
      }
    },
    [path, listings, fileDownload],
  )

  const handleViewerDownload = useCallback(async () => {
    if (!content) return
    const statRes = await fetchFileStat(content.path)
    if (statRes.ok && statRes.stat.size > DOWNLOAD_PROMPT_THRESHOLD) {
      setConfirmDialog({ path: content.path, size: statRes.stat.size })
    } else {
      void fileDownload.start(content.path)
    }
  }, [content, fileDownload])

  // ── Derive the rail ────────────────────────────────────────────────────

  // The rail is ALWAYS rooted at the filesystem root. It never re-roots on
  // navigation; only `expanded` (user-driven) changes what it shows.
  const rootListing = listings.get('/')

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

  const railNodes: FileTreeNode[] = rootListing ? buildNodes(rootListing) : []
  const railIsLoading = !rootListing

  // ── Derive the main pane ───────────────────────────────────────────────

  const isDirectoryTarget =
    path === null || path === '/' || listings.has(path)
  const listingForPane: FileListing | undefined =
    path === null ? listings.get(null) : listings.get(path)

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
              inflight.current.clear()
              setListings(new Map())
              setRailError(new Map())
              setRefreshTick((n) => n + 1)
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
        <Breadcrumbs path={path ?? rootListing?.path ?? '/'}>
          <div style={{ display: 'flex', alignItems: 'center', gap: 6, marginLeft: 'auto', fontSize: '0.85em', color: 'var(--text-muted)' }}>
            <input
              type="checkbox"
              id="show-hidden"
              checked={showHidden}
              onChange={(e) => setShowHidden(e.target.checked)}
              style={{ margin: 0 }}
            />
            <label htmlFor="show-hidden" style={{ cursor: 'pointer', userSelect: 'none' }}>
              Show hidden files
            </label>
          </div>
        </Breadcrumbs>
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
            showHidden={showHidden}
          />
        ) : null}
      </div>
      {fileDownload.progress && (
        <DownloadProgressUI
          progress={fileDownload.progress}
          onCancel={fileDownload.cancel}
          onRetry={fileDownload.retry}
        />
      )}
      {confirmDialog && (
        <DownloadConfirmDialog
          path={confirmDialog.path}
          size={confirmDialog.size}
          threshold={DOWNLOAD_PROMPT_THRESHOLD}
          onCancel={() => setConfirmDialog(null)}
          onPartial={() => {
            setConfirmDialog(null)
            void fileDownload.start(confirmDialog.path, DOWNLOAD_PROMPT_THRESHOLD)
          }}
          onFull={() => {
            setConfirmDialog(null)
            void fileDownload.start(confirmDialog.path)
          }}
        />
      )}
    </div>
  )
}
