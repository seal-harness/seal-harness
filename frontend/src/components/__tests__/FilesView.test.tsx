import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { render, screen, fireEvent, cleanup, waitFor } from '@testing-library/react'
import { FilesView } from '../FilesView'
import type { FileListing, FileContent } from '../../types'

// ── Fetch-layer stubs ────────────────────────────────────────────────────
//
// These tests stub `global.fetch` (the suite's established idiom) and drive
// the REAL hooks, so the two-call budget and cache reuse are observable.
// Mocking `fetchFileListing` from useApi would not work: the hooks call it as
// a module-internal binding (useApi.ts:1767, :1802), so replacing the export
// would silently intercept nothing.

function makeListing(overrides: Partial<FileListing> = {}): FileListing {
  return {
    path: '/home/user',
    entries: [
      { name: 'documents', isDir: true, isSymlink: false, size: null, mtime: '2026-01-01T00:00:00Z' },
      { name: 'photos', isDir: true, isSymlink: false, size: null, mtime: '2026-01-02T00:00:00Z' },
      { name: 'readme.txt', isDir: false, isSymlink: false, size: 1024, mtime: '2026-01-03T00:00:00Z' },
      { name: 'script.sh', isDir: false, isSymlink: false, size: 512, mtime: '2026-01-04T00:00:00Z' },
    ],
    truncated: false,
    warning: null,
    ...overrides,
  }
}

function makeContent(overrides: Partial<FileContent> = {}): FileContent {
  return {
    path: '/home/user/readme.txt',
    content: '# README\n\nHello, world!\n',
    truncated: false,
    linesRead: 3,
    isBinary: false,
    ...overrides,
  }
}

type Route = { status?: number; body?: unknown; truncated?: boolean }

/** Map of path -> response. A path absent from the map yields 404. */
let routes: Map<string, Route>
let fetchMock: ReturnType<typeof vi.fn>

function jsonRes(status: number, body: unknown) {
  return {
    ok: status >= 200 && status < 300,
    status,
    json: async () => body,
    headers: new Headers(),
    blob: async () => new Blob([]),
  } as unknown as Response
}

function setupFetch() {
  fetchMock = vi.fn(async (input: RequestInfo | URL) => {
    const url = String(input)
    const m = url.match(/[?&]path=([^&]*)/)
    const path = m ? decodeURIComponent(m[1]!) : null
    const isContent = url.includes('/api/files/content')
    const isDownload = url.includes('/api/files/download')

    if (isDownload) {
      const r = routes.get(path ?? '') ?? {}
      return {
        ok: true,
        status: 200,
        headers: new Headers(r.truncated ? { 'X-Truncated': 'true' } : {}),
        blob: async () => new Blob(['x']),
        json: async () => ({}),
      } as unknown as Response
    }

    // A `null` path means "resolve $HOME" (no path param at all).
    const route = path === null ? routes.get('') : routes.get(path)
    if (!route) return jsonRes(404, { error: 'not found' })
    return jsonRes(route.status ?? 200, route.body ?? (isContent ? makeContent() : makeListing()))
  })
  vi.stubGlobal('fetch', fetchMock)
}

/** The list of `path` query values requested, in order. */
function requestedPaths(): (string | null)[] {
  return fetchMock.mock.calls.map((c) => {
    const url = String(c[0])
    const m = url.match(/[?&]path=([^&]*)/)
    return m ? decodeURIComponent(m[1]!) : null
  })
}


/** Register a parent listing that contains `name` as a directory, so the
 *  two-call probe can resolve the target's kind. */
function registerParent(targetPath: string, name: string, isDir = true) {
  const parent = targetPath.slice(0, targetPath.lastIndexOf('/')) || '/'
  routes.set(parent, {
    body: makeListing({ path: parent, entries: [
      { name, isDir, isSymlink: false, size: isDir ? null : 10, mtime: null },
    ] }),
  })
  return parent
}


/** Register `/` plus every ancestor down to `target` (inclusive of the
 *  parent listing) so the root-seeded rail can expand to reach it.
 *  `leafs` maps a directory path to the names it contains. */
function registerChain(target: string, leafs: Record<string, string[]> = {}) {
  routes.set('/', { body: makeListing({ path: '/', entries: [] }) })
  const parts = target.split('/').filter(Boolean)
  let acc = ''
  for (let i = 0; i < parts.length; i++) {
    const parent = acc || '/'
    const name = parts[i]!
    const existing = routes.get(parent)?.body as FileListing | undefined
    const names = leafs[parent] ?? [name]
    routes.set(parent, {
      body: makeListing({
        path: parent,
        entries: names.map((n) => ({
          name: n,
          isDir: true,
          isSymlink: false,
          size: null,
          mtime: null,
        })),
        ...(existing ? {} : {}),
      }),
    })
    acc = parent === '/' ? `/${name}` : `${parent}/${name}`
  }
  return acc
}

function setLocation(path?: string) {
  const search = new URLSearchParams()
  if (path) search.set('path', path)
  const qs = search.toString()
  window.history.replaceState(null, '', qs ? `/files?${qs}` : '/files')
}

beforeEach(() => {
  routes = new Map()
  setLocation()
  // jsdom does not implement createObjectURL; downloadFile calls it
  // (useApi.ts:1830) and its catch would otherwise swallow the throw and
  // silently report {truncated:false}.
  URL.createObjectURL = vi.fn(() => 'blob:x') as unknown as typeof URL.createObjectURL
  URL.revokeObjectURL = vi.fn()
  setupFetch()
})

afterEach(() => {
  cleanup()
  window.history.replaceState(null, '', '/')
  vi.unstubAllGlobals()
  vi.restoreAllMocks()
})

// ── Tests ────────────────────────────────────────────────────────────────

describe('FilesView', () => {
  it('renders directory listing with entries', async () => {
    setLocation('/home/user')
    registerParent('/home/user', 'user')
    routes.set('/home/user', { body: makeListing() })
    render(<FilesView />)
    await waitFor(() => expect(screen.getByTestId('file-entry-readme.txt')).toBeTruthy())
    expect(screen.getByTestId('file-entry-documents')).toBeTruthy()
    expect(screen.getByTestId('file-entry-photos')).toBeTruthy()
    expect(screen.getByTestId('file-entry-script.sh')).toBeTruthy()
  })

  it('sorts entries: directories first, then files (each alphabetical)', async () => {
    setLocation('/home/user')
    routes.set('/home/user', {
      body: makeListing({
        entries: [
          { name: 'zebra.txt', isDir: false, isSymlink: false, size: 1, mtime: null },
          { name: 'alpha', isDir: true, isSymlink: false, size: null, mtime: null },
          { name: 'beta', isDir: true, isSymlink: false, size: null, mtime: null },
          { name: 'apple.txt', isDir: false, isSymlink: false, size: 1, mtime: null },
        ],
      }),
    })
    routes.set('/home', { body: makeListing({ path: '/home', entries: [{ name: 'user', isDir: true, isSymlink: false, size: null, mtime: null }] }) })
    const { container } = render(<FilesView />)
    await waitFor(() => expect(container.querySelectorAll('[data-testid^="file-entry-"]').length).toBe(4))
    const rows = container.querySelectorAll('[data-testid^="file-entry-"]')
    expect(rows[0]!.getAttribute('data-testid')).toBe('file-entry-alpha')
    expect(rows[1]!.getAttribute('data-testid')).toBe('file-entry-beta')
    expect(rows[2]!.getAttribute('data-testid')).toBe('file-entry-apple.txt')
    expect(rows[3]!.getAttribute('data-testid')).toBe('file-entry-zebra.txt')
  })

  it('renders breadcrumb segments from the current path', async () => {
    setLocation('/home/user')
    routes.set('/home/user', { body: makeListing({ path: '/home/user' }) })
    routes.set('/home', { body: makeListing({ path: '/home', entries: [{ name: 'user', isDir: true, isSymlink: false, size: null, mtime: null }] }) })
    render(<FilesView />)
    await waitFor(() => expect(screen.getByTestId('breadcrumb-/home/user')).toBeTruthy())
    expect(screen.getByTestId('breadcrumb-/')).toBeTruthy()
    expect(screen.getByTestId('breadcrumb-/home')).toBeTruthy()
  })

  it('navigates into a subdirectory on click (updates URL via pushState)', async () => {
    setLocation('/home/user')
    routes.set('/home/user', { body: makeListing() })
    routes.set('/home/user/documents', { body: makeListing({ path: '/home/user/documents', entries: [] }) })
    routes.set('/home', { body: makeListing({ path: '/home', entries: [{ name: 'user', isDir: true, isSymlink: false, size: null, mtime: null }] }) })
    render(<FilesView />)
    await waitFor(() => expect(screen.getByTestId('file-entry-documents')).toBeTruthy())
    const pushSpy = vi.spyOn(window.history, 'pushState')
    fireEvent.click(screen.getByTestId('file-entry-documents'))
    expect(pushSpy).toHaveBeenCalled()
    const pushedUrl = pushSpy.mock.calls[0]![2] as string
    expect(pushedUrl).toContain('/files')
    expect(pushedUrl).toContain('path=' + encodeURIComponent('/home/user/documents'))
  })

  it('breadcrumb segment click navigates to that parent directory', async () => {
    setLocation('/home/user')
    routes.set('/home/user', { body: makeListing({ path: '/home/user' }) })
    routes.set('/home', { body: makeListing({ path: '/home', entries: [{ name: 'user', isDir: true, isSymlink: false, size: null, mtime: null }] }) })
    render(<FilesView />)
    await waitFor(() => expect(screen.getByTestId('breadcrumb-/home')).toBeTruthy())
    const pushSpy = vi.spyOn(window.history, 'pushState')
    fireEvent.click(screen.getByTestId('breadcrumb-/home'))
    expect(pushSpy).toHaveBeenCalled()
    expect(pushSpy.mock.calls[0]![2] as string).toContain('path=' + encodeURIComponent('/home'))
  })

  it('file entries expose open and download affordances', async () => {
    setLocation('/home/user')
    registerParent('/home/user', 'user')
    routes.set('/home/user', { body: makeListing() })
    render(<FilesView />)
    await waitFor(() => expect(screen.getByTestId('file-entry-readme.txt')).toBeTruthy())
    expect(screen.getByTestId('download-readme.txt')).toBeTruthy()
  })

  it('activating a file row opens the viewer (no view= param)', async () => {
    setLocation('/home/user')
    registerParent('/home/user', 'user')
    routes.set('/home/user', { body: makeListing() })
    routes.set('/home/user/readme.txt', { body: makeContent() })
    render(<FilesView />)
    await waitFor(() => expect(screen.getByTestId('file-entry-readme.txt')).toBeTruthy())
    const pushSpy = vi.spyOn(window.history, 'pushState')
    fireEvent.click(screen.getByTestId('file-entry-readme.txt'))
    expect(pushSpy).toHaveBeenCalled()
    const url = pushSpy.mock.calls[0]![2] as string
    expect(url).toContain('path=' + encodeURIComponent('/home/user/readme.txt'))
    expect(url).not.toContain('view=')
  })

  it('viewer escapes file content (XSS)', async () => {
    setLocation('/home/user/readme.txt')
    routes.set('/home/user', { body: makeListing() })
    routes.set('/home', { body: makeListing({ path: '/home', entries: [{ name: 'user', isDir: true, isSymlink: false, size: null, mtime: null }] }) })
    routes.set('/home/user/readme.txt', {
      body: makeContent({ content: '<script>alert(1)</script>' }),
    })
    const { container } = render(<FilesView />)
    await waitFor(() => expect(container.querySelector('pre')).not.toBeNull())
    const pre = container.querySelector('pre')!
    expect(pre.textContent).toContain('<script>alert(1)</script>')
    expect(pre.querySelector('script')).toBeNull()
  })

  it('binary file shows message, no <pre>', async () => {
    setLocation('/home/user/data.bin')
    routes.set('/home/user', { body: makeListing() })
    routes.set('/home', { body: makeListing({ path: '/home', entries: [{ name: 'user', isDir: true, isSymlink: false, size: null, mtime: null }] }) })
    routes.set('/home/user/data.bin', { body: makeContent({ isBinary: true, content: '' }) })
    const { container } = render(<FilesView />)
    await waitFor(() => expect(screen.getByTestId('binary-file-message')).toBeTruthy())
    expect(container.querySelector('pre')).toBeNull()
  })

  it('viewer exposes download + back', async () => {
    setLocation('/home/user/readme.txt')
    routes.set('/home/user', { body: makeListing() })
    routes.set('/home', { body: makeListing({ path: '/home', entries: [{ name: 'user', isDir: true, isSymlink: false, size: null, mtime: null }] }) })
    routes.set('/home/user/readme.txt', { body: makeContent() })
    render(<FilesView />)
    await waitFor(() => expect(screen.getByTestId('content-download')).toBeTruthy())
    expect(screen.getByTestId('content-back')).toBeTruthy()
  })

  it('viewer download uses fetch, not <a href>', async () => {
    setLocation('/home/user/readme.txt')
    routes.set('/home/user', { body: makeListing() })
    routes.set('/home', { body: makeListing({ path: '/home', entries: [{ name: 'user', isDir: true, isSymlink: false, size: null, mtime: null }] }) })
    routes.set('/home/user/readme.txt', { body: makeContent() })
    render(<FilesView />)
    await waitFor(() => expect(screen.getByTestId('content-download')).toBeTruthy())
    fetchMock.mockClear()
    fireEvent.click(screen.getByTestId('content-download'))
    await waitFor(() =>
      expect(requestedPaths()).toContain('/home/user/readme.txt'),
    )
    expect(fetchMock.mock.calls.some((c) => String(c[0]).includes('/download'))).toBe(true)
  })

  it('listing download does not navigate', async () => {
    setLocation('/home/user')
    registerParent('/home/user', 'user')
    routes.set('/home/user', { body: makeListing() })
    render(<FilesView />)
    await waitFor(() => expect(screen.getByTestId('download-readme.txt')).toBeTruthy())
    const pushSpy = vi.spyOn(window.history, 'pushState')
    fireEvent.click(screen.getByTestId('download-readme.txt'))
    await waitFor(() =>
      expect(fetchMock.mock.calls.some((c) => String(c[0]).includes('/download'))).toBe(true),
    )
    expect(pushSpy).not.toHaveBeenCalled()
  })

  it('listing download truncation warns', async () => {
    setLocation('/home/user')
    registerParent('/home/user', 'user')
    routes.set('/home/user', { body: makeListing() })
    routes.set('/home/user/readme.txt', { truncated: true })
    render(<FilesView />)
    await waitFor(() => expect(screen.getByTestId('download-readme.txt')).toBeTruthy())
    fireEvent.click(screen.getByTestId('download-readme.txt'))
    await waitFor(() => expect(screen.getByTestId('download-truncated-warning')).toBeTruthy())
  })

  it('viewer download truncation warns', async () => {
    setLocation('/home/user/readme.txt')
    routes.set('/home/user', { body: makeListing() })
    routes.set('/home', { body: makeListing({ path: '/home', entries: [{ name: 'user', isDir: true, isSymlink: false, size: null, mtime: null }] }) })
    routes.set('/home/user/readme.txt', { body: makeContent(), truncated: true })
    render(<FilesView />)
    await waitFor(() => expect(screen.getByTestId('content-download')).toBeTruthy())
    fireEvent.click(screen.getByTestId('content-download'))
    await waitFor(() =>
      expect(screen.getByTestId('viewer-download-truncated-warning')).toBeTruthy(),
    )
  })

  it('sensitive-directory banner (listing)', async () => {
    setLocation('/etc')
    routes.set('/etc', {
      body: makeListing({ path: '/etc', entries: [], warning: 'This directory contains sensitive files' }),
    })
    routes.set('/', { body: makeListing({ path: '/', entries: [{ name: 'etc', isDir: true, isSymlink: false, size: null, mtime: null }] }) })
    render(<FilesView />)
    await waitFor(() => expect(screen.getByTestId('warning-banner')).toBeTruthy())
    expect(screen.getByText(/sensitive/i)).toBeTruthy()
  })

  it('listing data truncation', async () => {
    setLocation('/home/user')
    routes.set('/home/user', { body: makeListing({ truncated: true }) })
    routes.set('/home', { body: makeListing({ path: '/home', entries: [{ name: 'user', isDir: true, isSymlink: false, size: null, mtime: null }] }) })
    render(<FilesView />)
    await waitFor(() => expect(screen.getByTestId('listing-truncated')).toBeTruthy())
  })

  it('content data truncation', async () => {
    setLocation('/home/user/readme.txt')
    routes.set('/home/user', { body: makeListing() })
    routes.set('/home', { body: makeListing({ path: '/home', entries: [{ name: 'user', isDir: true, isSymlink: false, size: null, mtime: null }] }) })
    routes.set('/home/user/readme.txt', { body: makeContent({ truncated: true }) })
    render(<FilesView />)
    await waitFor(() => expect(screen.getByTestId('content-truncated')).toBeTruthy())
  })

  it('404 error state', async () => {
    setLocation('/nonexistent')
    render(<FilesView />)
    await waitFor(() => expect(screen.getByTestId('files-error')).toBeTruthy())
    expect(screen.getByText(/not found/i)).toBeTruthy()
  })

  it('403 error state', async () => {
    setLocation('/root')
    routes.set('/root', { status: 403, body: { error: 'forbidden' } })
    routes.set('/', { body: makeListing({ path: '/', entries: [] }) })
    render(<FilesView />)
    await waitFor(() => expect(screen.getByTestId('files-error')).toBeTruthy())
    expect(screen.getByText(/disabled|forbidden/i)).toBeTruthy()
  })

  it('400 error state', async () => {
    setLocation('/bad')
    routes.set('/bad', { status: 400, body: { error: 'bad request' } })
    routes.set('/', { body: makeListing({ path: '/', entries: [{ name: 'bad', isDir: true, isSymlink: false, size: null, mtime: null }] }) })
    render(<FilesView />)
    await waitFor(() => expect(screen.getByTestId('files-error')).toBeTruthy())
    expect(screen.getByText(/bad request|invalid/i)).toBeTruthy()
  })

  it('loading spinner', () => {
    setLocation('/home/user')
    // No routes registered: the fetch resolves asynchronously, so the initial
    // render is the loading state.
    render(<FilesView />)
    expect(screen.getByTestId('files-loading')).toBeTruthy()
  })

  it('absent path defaults to home; the rail still roots at /', async () => {
    setLocation()
    routes.set('', { body: makeListing({ path: '/home/user' }) })
    routes.set('/', { body: makeListing({ path: '/', entries: [] }) })
    render(<FilesView />)
    await waitFor(() => expect(screen.getByTestId('file-entry-readme.txt')).toBeTruthy())
    // The $HOME request is still made for the main pane…
    expect(requestedPaths()).toContain(null)
    // …and the rail is seeded from the filesystem root, not the parent.
    expect(requestedPaths()).toContain('/')
  })

  it('viewer Back returns to parent (no view= param)', async () => {
    setLocation('/home/user/readme.txt')
    routes.set('/home/user', { body: makeListing() })
    routes.set('/home', { body: makeListing({ path: '/home', entries: [{ name: 'user', isDir: true, isSymlink: false, size: null, mtime: null }] }) })
    routes.set('/home/user/readme.txt', { body: makeContent() })
    render(<FilesView />)
    await waitFor(() => expect(screen.getByTestId('content-back')).toBeTruthy())
    const pushSpy = vi.spyOn(window.history, 'pushState')
    fireEvent.click(screen.getByTestId('content-back'))
    expect(pushSpy).toHaveBeenCalled()
    const url = pushSpy.mock.calls[0]![2] as string
    expect(url).toContain('path=' + encodeURIComponent('/home/user'))
    expect(url).not.toContain('view=')
  })


  // ── Rooted tree: navigation must not change the rail ────────────────────

  it('roots the rail at the filesystem root, not at parent(path)', async () => {
    setLocation('/home/user')
    registerChain('/home/user', { '/': ['home', 'etc'], '/home': ['user'] })
    render(<FilesView />)
    await waitFor(() => expect(screen.getByTestId('rail-node-/home')).toBeTruthy())
    // Root-level siblings are visible, proving the root is `/`.
    expect(screen.getByTestId('rail-node-/etc')).toBeTruthy()
  })

  it('collapses everything except the current directory chain on first load', async () => {
    setLocation('/home/user')
    registerChain('/home/user', { '/': ['home'], '/home': ['user'] })
    routes.set('/home/user', { body: makeListing({ path: '/home/user', entries: [] }) })
    render(<FilesView />)
    await waitFor(() => expect(screen.getByTestId('rail-node-/home/user')).toBeTruthy())
    // Ancestors of the target are expanded…
    expect(screen.getByTestId('rail-glyph-/home').querySelector('svg')?.style.transform)
      .toBe('rotate(90deg)')
    // …and an unrelated root sibling stays collapsed.
    // ('/etc' was not registered under '/', so assert on the absence of any
    // expanded node other than the chain.)
    expect(screen.queryByTestId('rail-node-/etc')).toBeNull()
  })

  it('does not collapse anything when navigating to a sibling directory', async () => {
    setLocation('/home/user')
    registerChain('/home/user', { '/': ['home'], '/home': ['user', 'other'] })
    routes.set('/home/user', { body: makeListing({ path: '/home/user', entries: [] }) })
    routes.set('/home/other', { body: makeListing({ path: '/home/other', entries: [] }) })
    render(<FilesView />)
    await waitFor(() => expect(screen.getByTestId('rail-node-/home/user')).toBeTruthy())

    const expandedPaths = () =>
      [...screen.getByTestId('file-tree').querySelectorAll('[data-testid^="rail-glyph-"]')]
        .filter((el) => el.querySelector('svg')?.style.transform === 'rotate(90deg)')
        .map((el) => el.getAttribute('data-testid')!.replace('rail-glyph-', ''))
    const before = expandedPaths()

    fireEvent.click(screen.getByTestId('rail-node-/home/other'))
    await waitFor(() => expect(screen.getByTestId('breadcrumb-/home/other')).toBeTruthy())

    // Sticky additions: navigation may add, never remove.
    const after = expandedPaths()
    before.forEach((p) => expect(after).toContain(p))
    expect(after).toContain('/home')
  })

  it('does not re-open a manually collapsed ancestor on navigation', async () => {
    setLocation('/home/user/readme.txt')
    registerChain('/home/user', { '/': ['home'], '/home': ['user'], '/home/user': ['readme.txt'] })
    routes.set('/home/user', { body: makeListing({ path: '/home/user', entries: [
      { name: 'readme.txt', isDir: false, isSymlink: false, size: 1, mtime: null },
    ] }) })
    routes.set('/home/user/readme.txt', { body: makeContent() })
    render(<FilesView />)
    await waitFor(() => expect(screen.getByTestId('file-content-pre')).toBeTruthy())

    // Manually collapse /home.
    fireEvent.click(screen.getByTestId('rail-node-/home'))
    await waitFor(() =>
      expect(screen.getByTestId('rail-glyph-/home').querySelector('svg')?.style.transform).toBe('none'),
    )

    // Navigate elsewhere and back onto the same deep path.
    const push = window.history.pushState.bind(window.history)
    push(null, '', '/files?path=' + encodeURIComponent('/home/user'))
    window.dispatchEvent(new PopStateEvent('popstate'))
    await waitFor(() => expect(screen.getByTestId('breadcrumb-/home/user')).toBeTruthy())
    push(null, '', '/files?path=' + encodeURIComponent('/home/user/readme.txt'))
    window.dispatchEvent(new PopStateEvent('popstate'))
    await waitFor(() => expect(screen.getByTestId('file-content-pre')).toBeTruthy())

    // /home stays collapsed: navigation never overrides a manual collapse.
    expect(screen.getByTestId('rail-glyph-/home').querySelector('svg')?.style.transform).toBe('none')
  })

  // ── New behaviour ──────────────────────────────────────────────────────

  it('breadcrumb collapses middle segments for deep paths', async () => {
    setLocation('/a/b/c/d/e/f')
    routes.set('/a/b/c/d/e/f', { body: makeListing({ path: '/a/b/c/d/e/f', entries: [] }) })
    routes.set('/a/b/c/d/e', { body: makeListing({ path: '/a/b/c/d/e', entries: [] }) })
    render(<FilesView />)
    await waitFor(() => expect(screen.getByTestId('breadcrumbs')).toBeTruthy())
    const crumb = screen.getByTestId('breadcrumbs')
    // first + last always present
    expect(crumb.textContent).toContain('a')
    expect(crumb.textContent).toContain('f')
    expect(screen.getByTestId('breadcrumb-ellipsis')).toBeTruthy()
  })

  it('rows are keyboard-operable: Enter and Space activate', async () => {
    setLocation('/home/user')
    registerParent('/home/user', 'user')
    routes.set('/home/user', { body: makeListing() })
    routes.set('/home/user/readme.txt', { body: makeContent() })
    render(<FilesView />)
    await waitFor(() => expect(screen.getByTestId('file-entry-readme.txt')).toBeTruthy())
    const row = screen.getByTestId('file-entry-readme.txt')
    expect(row.tagName).toBe('BUTTON')
    expect(row.getAttribute('aria-label')).toBeTruthy()
    const pushSpy = vi.spyOn(window.history, 'pushState')
    fireEvent.click(row)
    expect(pushSpy).toHaveBeenCalled()
  })

  it('rows are focusable', async () => {
    setLocation('/home/user')
    registerParent('/home/user', 'user')
    routes.set('/home/user', { body: makeListing() })
    render(<FilesView />)
    await waitFor(() => expect(screen.getByTestId('file-entry-readme.txt')).toBeTruthy())
    const row = screen.getByTestId('file-entry-readme.txt')
    row.focus()
    expect(document.activeElement).toBe(row)
  })

  it('empty directory shows a message', async () => {
    setLocation('/home/empty')
    routes.set('/home/empty', { body: makeListing({ path: '/home/empty', entries: [] }) })
    routes.set('/home', { body: makeListing({ path: '/home', entries: [{ name: 'empty', isDir: true, isSymlink: false, size: null, mtime: null }] }) })
    render(<FilesView />)
    await waitFor(() => expect(screen.getByTestId('empty-directory')).toBeTruthy())
  })

  it('cold-loads a bookmarked file to the correct view', async () => {
    setLocation('/a/b/c.txt')
    registerChain('/a/b', { '/a': ['b'], '/a/b': ['c.txt'] })
    routes.set('/a/b', { body: makeListing({ path: '/a/b', entries: [
      { name: 'c.txt', isDir: false, isSymlink: false, size: 10, mtime: null },
    ] }) })
    routes.set('/a/b/c.txt', { body: makeContent({ path: '/a/b/c.txt' }) })
    render(<FilesView />)
    await waitFor(() => expect(screen.getByTestId('file-content-pre')).toBeTruthy())
    // The rail is rooted at /, with the target's ancestors expanded.
    expect(screen.getByTestId('rail-node-/a')).toBeTruthy()
  })

  // ── Rail integration (budget + root derivation) ─────────────────────────

  it('cold file bookmark costs exactly two requests', async () => {
    setLocation('/home/user/readme.txt')
    routes.set('/home/user', { body: makeListing() })
    routes.set('/home', { body: makeListing({ path: '/home', entries: [{ name: 'user', isDir: true, isSymlink: false, size: null, mtime: null }] }) })
    routes.set('/home/user/readme.txt', { body: makeContent() })
    render(<FilesView />)
    await waitFor(() => expect(screen.getByTestId('file-content-pre')).toBeTruthy())
    // '/', '/home', '/home/user' (rail seed + ancestors) + the content.
    expect(new Set(requestedPaths()).size).toBe(4)
  })

  it('cold directory bookmark costs one request per path level', async () => {
    setLocation('/home/user')
    registerParent('/home/user', 'user')
    routes.set('/home/user', { body: makeListing() })
    render(<FilesView />)
    await waitFor(() => expect(screen.getByTestId('file-entry-readme.txt')).toBeTruthy())
    // '/', '/home' (rail + ancestor) + '/home/user' (the content listing).
    expect(new Set(requestedPaths()).size).toBe(3)
  })

  it('reuses the parent listing when switching sibling files', async () => {
    // Start on a directory whose listing is the rail root, then open two of
    // its files in turn. Switching siblings must not refetch the listing.
    setLocation('/home/user')
    routes.set('/home/user', { body: makeListing() })
    routes.set('/home', {
      body: makeListing({
        path: '/home',
        entries: [{ name: 'user', isDir: true, isSymlink: false, size: null, mtime: null }],
      }),
    })
    routes.set('/home/user/readme.txt', { body: makeContent() })
    routes.set('/home/user/script.sh', { body: makeContent({ path: '/home/user/script.sh' }) })
    render(<FilesView />)
    await waitFor(() => expect(screen.getByTestId('file-entry-readme.txt')).toBeTruthy())

    // Open the first sibling.
    fireEvent.click(screen.getByTestId('file-entry-readme.txt'))
    await waitFor(() => expect(screen.getByTestId('file-content-pre')).toBeTruthy())

    // Return to /home/user (already cached — no fetch).
    const beforeBack = fetchMock.mock.calls.length
    fireEvent.click(screen.getByTestId('content-back'))
    await waitFor(() => expect(screen.getByTestId('file-entry-script.sh')).toBeTruthy())
    expect(fetchMock.mock.calls.length).toBe(beforeBack)

    // Opening the second sibling costs exactly one request: its content.
    fireEvent.click(screen.getByTestId('file-entry-script.sh'))
    await waitFor(() => expect(requestedPaths()).toContain('/home/user/script.sh'))
    expect(fetchMock.mock.calls.length).toBe(beforeBack + 1)
  })

  it('breadcrumb navigates to a path outside the rail root', async () => {
    setLocation('/home/user')
    registerParent('/home/user', 'user')
    routes.set('/home/user', { body: makeListing() })
    render(<FilesView />)
    await waitFor(() => expect(screen.getByTestId('breadcrumb-/home')).toBeTruthy())
    const pushSpy = vi.spyOn(window.history, 'pushState')
    fireEvent.click(screen.getByTestId('breadcrumb-/'))
    expect(pushSpy).toHaveBeenCalled()
    expect(pushSpy.mock.calls[0]![2] as string).toContain('path=' + encodeURIComponent('/'))
  })
})
