import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { render, screen, fireEvent, cleanup, waitFor } from '@testing-library/react'
import { FilesView } from '../FilesView'
import type { FileListing, FileContent } from '../../types'

// ── Mocks ────────────────────────────────────────────────────────────────

const useFileListing = vi.fn()
const useFileContent = vi.fn()
const downloadFile = vi.fn()

vi.mock('../../hooks/useApi', () => ({
  useFileListing: (path: string | null | undefined) => useFileListing(path),
  useFileContent: (path: string | null | undefined) => useFileContent(path),
  downloadFile: (path: string) => downloadFile(path),
}))

// ── Helpers ──────────────────────────────────────────────────────────────

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

/** Set window.location to a /files URL with a path query param. */
function setLocation(path?: string, view?: string) {
  const search = new URLSearchParams()
  if (path) search.set('path', path)
  if (view) search.set('view', view)
  const qs = search.toString()
  window.history.replaceState(null, '', qs ? `/files?${qs}` : '/files')
}

function setupListing(listing: FileListing | null, opts: { loading?: boolean; error?: number | null } = {}) {
  useFileListing.mockReturnValue({
    listing,
    loading: opts.loading ?? false,
    error: opts.error ?? null,
    refresh: vi.fn(),
  })
}

function setupContent(content: FileContent | null, opts: { loading?: boolean; error?: number | null } = {}) {
  useFileContent.mockReturnValue({
    content,
    loading: opts.loading ?? false,
    error: opts.error ?? null,
    refresh: vi.fn(),
  })
}

beforeEach(() => {
  setLocation()
  useFileListing.mockReset()
  useFileContent.mockReset()
  downloadFile.mockReset()
  // Default: empty listing, no error
  setupListing(makeListing())
  setupContent(makeContent())
  downloadFile.mockResolvedValue({ truncated: false })
})

afterEach(() => {
  cleanup()
  window.history.replaceState(null, '', '/')
  vi.restoreAllMocks()
})

// ── Tests ────────────────────────────────────────────────────────────────

describe('FilesView', () => {
  it('renders directory listing with entries', () => {
    setLocation('/home/user')
    setupListing(makeListing())
    render(<FilesView />)
    expect(screen.getByText('documents')).toBeTruthy()
    expect(screen.getByText('photos')).toBeTruthy()
    expect(screen.getByText('readme.txt')).toBeTruthy()
    expect(screen.getByText('script.sh')).toBeTruthy()
  })

  it('sorts entries: directories first, then files (each alphabetical)', () => {
    setLocation('/home/user')
    setupListing(makeListing({
      entries: [
        { name: 'zebra.txt', isDir: false, isSymlink: false, size: 1, mtime: null },
        { name: 'alpha', isDir: true, isSymlink: false, size: null, mtime: null },
        { name: 'beta', isDir: true, isSymlink: false, size: null, mtime: null },
        { name: 'apple.txt', isDir: false, isSymlink: false, size: 1, mtime: null },
      ],
    }))
    const { container } = render(<FilesView />)
    const rows = container.querySelectorAll('[data-testid^="file-entry-"]')
    // dirs first (alpha, beta), then files (apple.txt, zebra.txt)
    expect(rows[0]!.getAttribute('data-testid')).toBe('file-entry-alpha')
    expect(rows[1]!.getAttribute('data-testid')).toBe('file-entry-beta')
    expect(rows[2]!.getAttribute('data-testid')).toBe('file-entry-apple.txt')
    expect(rows[3]!.getAttribute('data-testid')).toBe('file-entry-zebra.txt')
  })

  it('renders breadcrumb segments from the current path', () => {
    setLocation('/home/user')
    setupListing(makeListing({ path: '/home/user' }))
    render(<FilesView />)
    expect(screen.getByTestId('breadcrumb-/')).toBeTruthy()
    expect(screen.getByTestId('breadcrumb-/home')).toBeTruthy()
    expect(screen.getByTestId('breadcrumb-/home/user')).toBeTruthy()
    expect(screen.getByText('user')).toBeTruthy()
  })

  it('navigates into a subdirectory on click (updates URL via pushState)', () => {
    setLocation('/home/user')
    setupListing(makeListing())
    const pushSpy = vi.spyOn(window.history, 'pushState')
    render(<FilesView />)
    fireEvent.click(screen.getByTestId('file-entry-documents'))
    expect(pushSpy).toHaveBeenCalled()
    const pushedUrl = pushSpy.mock.calls[0]![2] as string
    expect(pushedUrl).toContain('/files')
    expect(pushedUrl).toContain('path=')
    expect(encodeURIComponent('/home/user/documents')).toBe(
      pushedUrl.split('path=')[1],
    )
  })

  it('breadcrumb segment click navigates to that parent directory', () => {
    setLocation('/home/user')
    setupListing(makeListing({ path: '/home/user' }))
    const pushSpy = vi.spyOn(window.history, 'pushState')
    render(<FilesView />)
    fireEvent.click(screen.getByTestId('breadcrumb-/home'))
    expect(pushSpy).toHaveBeenCalled()
    const pushedUrl = pushSpy.mock.calls[0]![2] as string
    expect(pushedUrl).toContain('path=' + encodeURIComponent('/home'))
  })

  it('file entries have a View link and Download button', () => {
    setLocation('/home/user')
    setupListing(makeListing())
    render(<FilesView />)
    expect(screen.getByTestId('view-readme.txt')).toBeTruthy()
    expect(screen.getByTestId('download-readme.txt')).toBeTruthy()
  })

  it('View link navigates to content view (view=content)', () => {
    setLocation('/home/user')
    setupListing(makeListing())
    const pushSpy = vi.spyOn(window.history, 'pushState')
    render(<FilesView />)
    fireEvent.click(screen.getByTestId('view-readme.txt'))
    expect(pushSpy).toHaveBeenCalled()
    const pushedUrl = pushSpy.mock.calls[0]![2] as string
    expect(pushedUrl).toContain('view=content')
    expect(pushedUrl).toContain('path=' + encodeURIComponent('/home/user/readme.txt'))
  })

  it('shows file content view in text-escaped <pre> block when view=content', () => {
    setLocation('/home/user/readme.txt', 'content')
    setupContent(makeContent({ content: '<script>alert(1)</script>' }))
    const { container } = render(<FilesView />)
    const pre = container.querySelector('pre')
    expect(pre).not.toBeNull()
    // The raw text is rendered (text-escaped by React), not executed HTML.
    expect(pre!.textContent).toContain('<script>alert(1)</script>')
    // No actual <script> element inside the <pre>
    expect(pre!.querySelector('script')).toBeNull()
  })

  it('shows binary file message when isBinary is true', () => {
    setLocation('/home/user/data.bin', 'content')
    setupContent(makeContent({ isBinary: true, content: '' }))
    render(<FilesView />)
    expect(screen.getByTestId('binary-file-message')).toBeTruthy()
    // The <pre> should NOT be rendered for binary files
    expect(document.querySelector('pre')).toBeNull()
  })

  it('shows Download and Back buttons in content view', () => {
    setLocation('/home/user/readme.txt', 'content')
    setupContent(makeContent())
    render(<FilesView />)
    expect(screen.getByTestId('content-download')).toBeTruthy()
    expect(screen.getByTestId('content-back')).toBeTruthy()
  })

  it('download button in content view calls downloadFile (fetch, not <a href>)', async () => {
    setLocation('/home/user/readme.txt', 'content')
    setupContent(makeContent())
    downloadFile.mockResolvedValue({ truncated: false })
    render(<FilesView />)
    fireEvent.click(screen.getByTestId('content-download'))
    await waitFor(() => expect(downloadFile).toHaveBeenCalledWith('/home/user/readme.txt'))
  })

  it('download button in listing calls downloadFile via fetch', async () => {
    setLocation('/home/user')
    setupListing(makeListing())
    downloadFile.mockResolvedValue({ truncated: false })
    render(<FilesView />)
    fireEvent.click(screen.getByTestId('download-readme.txt'))
    await waitFor(() => expect(downloadFile).toHaveBeenCalledWith('/home/user/readme.txt'))
  })

  it('shows truncation warning in listing when download X-Truncated is true', async () => {
    setLocation('/home/user')
    setupListing(makeListing())
    downloadFile.mockResolvedValue({ truncated: true })
    render(<FilesView />)
    fireEvent.click(screen.getByTestId('download-readme.txt'))
    await waitFor(() => expect(downloadFile).toHaveBeenCalled())
    expect(screen.getByTestId('download-truncated-warning')).toBeTruthy()
  })

  it('shows truncation warning toast when download X-Truncated is true', async () => {
    setLocation('/home/user/readme.txt', 'content')
    setupContent(makeContent())
    downloadFile.mockResolvedValue({ truncated: true })
    render(<FilesView />)
    fireEvent.click(screen.getByTestId('content-download'))
    await waitFor(() => expect(downloadFile).toHaveBeenCalled())
    expect(screen.getByTestId('download-truncation-warning')).toBeTruthy()
  })

  it('shows warning banner for sensitive directories', () => {
    setLocation('/etc')
    setupListing(makeListing({ path: '/etc', warning: 'Sensitive system directory' }))
    render(<FilesView />)
    expect(screen.getByTestId('warning-banner')).toBeTruthy()
    expect(screen.getByText(/Sensitive system directory/)).toBeTruthy()
  })

  it('shows truncation indicator when listing truncated is true', () => {
    setLocation('/home/user')
    setupListing(makeListing({ truncated: true }))
    render(<FilesView />)
    expect(screen.getByTestId('listing-truncated')).toBeTruthy()
  })

  it('shows truncation indicator when content truncated is true', () => {
    setLocation('/home/user/readme.txt', 'content')
    setupContent(makeContent({ truncated: true }))
    render(<FilesView />)
    expect(screen.getByTestId('content-truncated')).toBeTruthy()
  })

  it('shows error message for 404', () => {
    setLocation('/nonexistent')
    setupListing(null, { error: 404 })
    render(<FilesView />)
    expect(screen.getByTestId('files-error')).toBeTruthy()
    expect(screen.getByText(/not found/i)).toBeTruthy()
  })

  it('shows error message for 403', () => {
    setLocation('/root')
    setupListing(null, { error: 403 })
    render(<FilesView />)
    expect(screen.getByTestId('files-error')).toBeTruthy()
    expect(screen.getByText(/disabled|forbidden/i)).toBeTruthy()
  })

  it('shows error message for 400', () => {
    setLocation('')
    setupListing(null, { error: 400 })
    render(<FilesView />)
    expect(screen.getByTestId('files-error')).toBeTruthy()
    expect(screen.getByText(/bad request|invalid/i)).toBeTruthy()
  })

  it('shows loading spinner while fetching', () => {
    setLocation('/home/user')
    setupListing(null, { loading: true })
    render(<FilesView />)
    expect(screen.getByTestId('files-loading')).toBeTruthy()
  })

  it('defaults to home directory when no path query param', () => {
    setLocation()  // no path
    setupListing(makeListing({ path: '/home/user', entries: [] }))
    render(<FilesView />)
    // The hook should have been called with null/undefined (home default)
    expect(useFileListing).toHaveBeenCalledWith(null)
  })

  it('Back button returns to the parent directory listing', () => {
    setLocation('/home/user/readme.txt', 'content')
    setupContent(makeContent())
    const pushSpy = vi.spyOn(window.history, 'pushState')
    render(<FilesView />)
    fireEvent.click(screen.getByTestId('content-back'))
    expect(pushSpy).toHaveBeenCalled()
    const pushedUrl = pushSpy.mock.calls[0]![2] as string
    expect(pushedUrl).toContain('path=' + encodeURIComponent('/home/user'))
    expect(pushedUrl).not.toContain('view=content')
  })
})
