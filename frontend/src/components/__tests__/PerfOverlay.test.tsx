import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { render, screen, fireEvent, cleanup, act } from '@testing-library/react'
import { PerfOverlay } from '../PerfOverlay'
import * as perf from '../../lib/perf'

beforeEach(() => {
  // Ensure a clean slate and instrumentation off before each test.
  perf.setEnabled(false)
})

afterEach(() => {
  perf.setEnabled(false)
  cleanup()
})

describe('PerfOverlay', () => {
  it('renders nothing by default (perf disabled)', () => {
    render(<PerfOverlay />)
    expect(screen.queryByTestId('perf-overlay')).toBeNull()
  })

  it('appears when perf is enabled via Ctrl+Shift+P', async () => {
    render(<PerfOverlay />)
    await act(async () => {
      fireEvent.keyDown(window, {
        key: 'P',
        ctrlKey: true,
        shiftKey: true,
      })
    })
    expect(screen.getByTestId('perf-overlay')).toBeDefined()
    expect(perf.isEnabled()).toBe(true)
  })

  it('also accepts Cmd+Shift+P (macOS)', async () => {
    render(<PerfOverlay />)
    await act(async () => {
      fireEvent.keyDown(window, {
        key: 'p',
        metaKey: true,
        shiftKey: true,
      })
    })
    expect(screen.getByTestId('perf-overlay')).toBeDefined()
  })

  it('disappears when toggled off with the same shortcut', async () => {
    render(<PerfOverlay />)
    // Turn on:
    await act(async () => {
      fireEvent.keyDown(window, { key: 'P', ctrlKey: true, shiftKey: true })
    })
    expect(screen.getByTestId('perf-overlay')).toBeDefined()
    // Turn off:
    await act(async () => {
      fireEvent.keyDown(window, { key: 'P', ctrlKey: true, shiftKey: true })
    })
    expect(screen.queryByTestId('perf-overlay')).toBeNull()
  })

  it('ignores unrelated key combos', async () => {
    render(<PerfOverlay />)
    await act(async () => {
      fireEvent.keyDown(window, { key: 'P', shiftKey: true }) // missing Ctrl/Cmd
    })
    expect(screen.queryByTestId('perf-overlay')).toBeNull()
    await act(async () => {
      fireEvent.keyDown(window, { key: 'X', ctrlKey: true, shiftKey: true })
    })
    expect(screen.queryByTestId('perf-overlay')).toBeNull()
  })

  it('shows a "no samples yet" placeholder before any work is recorded', async () => {
    render(<PerfOverlay />)
    await act(async () => {
      fireEvent.keyDown(window, { key: 'P', ctrlKey: true, shiftKey: true })
    })
    expect(screen.getByTestId('perf-overlay').textContent).toMatch(/No samples yet/)
  })

  it('renders recorded samples grouped by category', async () => {
    render(<PerfOverlay />)
    await act(async () => {
      fireEvent.keyDown(window, { key: 'P', ctrlKey: true, shiftKey: true })
    })
    // Record samples inside act() so React flushes the state update that
    // notify() triggers via the subscribed setter.
    await act(async () => {
      perf.record('transcript.test', { durMs: 12.3, count: 5 })
      perf.record('render.ChatArea.messageList', { durMs: 4.2 })
    })
    const overlay = screen.getByTestId('perf-overlay')
    expect(overlay.textContent).toMatch(/transcript\.test/)
    expect(overlay.textContent).toMatch(/12\.3ms/)
    expect(overlay.textContent).toMatch(/n=5/)
    expect(overlay.textContent).toMatch(/React render/)
  })

  it('Copy report button writes a text summary to the clipboard', async () => {
    const clipboardText: string[] = []
    const origWrite = navigator.clipboard?.writeText
    Object.defineProperty(navigator, 'clipboard', {
      value: { writeText: (t: string) => { clipboardText.push(t); return Promise.resolve() } },
      configurable: true,
      writable: true,
    })
    try {
      render(<PerfOverlay />)
      await act(async () => {
        fireEvent.keyDown(window, { key: 'P', ctrlKey: true, shiftKey: true })
      })
      await act(async () => {
        perf.record('transcript.seed', { durMs: 42, count: 127, meta: { source: 'conv+entries', sessionId: 's1' } })
        perf.record('server.transcript.seed.total', { durMs: 42, meta: { source: 'conv+entries', count: 127 } })
        perf.record('reconcileEntries', { durMs: 0.8, count: 127, meta: { mode: 'replace' } })
        perf.record('render.ChatArea.messageList', { durMs: 16 })
      })
      const btn = screen.getByTestId('perf-copy-report')
      await act(async () => { fireEvent.click(btn) })
      expect(clipboardText).toHaveLength(1)
      const report = clipboardText[0]!
      // Structured header:
      expect(report).toMatch(/# Perf report/)
      // Each group present:
      expect(report).toMatch(/## Transcript \(frontend\)/)
      expect(report).toMatch(/## Transcript \(server phases\)/)
      expect(report).toMatch(/## React render/)
      expect(report).toMatch(/## WS reconcile/)
      // Per-op stats with min/med/max + sample count:
      expect(report).toMatch(/transcript\.seed: min=\d+(\.\d+)? med=\d+(\.\d+)? max=\d+(\.\d+)? \(1 samples, latest: n=127 source=conv\+entries sessionId=s1\)/)
      expect(report).toMatch(/reconcileEntries: min=0\.8 med=0\.8 max=0\.8 \(1 samples, latest: n=127 mode=replace\)/)
      // The button shows a transient "Copied" state:
      expect(screen.getByTestId('perf-copy-report').textContent).toMatch(/Copied/)
    } finally {
      if (origWrite !== undefined) {
        Object.defineProperty(navigator, 'clipboard', { value: { writeText: origWrite }, configurable: true, writable: true })
      }
    }
  })

  it('falls back to a visible textarea when the clipboard API is unavailable', async () => {
    // Simulate an insecure context: navigator.clipboard is undefined AND
    // execCommand returns false (e.g. older browser). The overlay must
    // surface the report text so the user can select+copy manually.
    const origClipboard = navigator.clipboard
    Object.defineProperty(navigator, 'clipboard', { value: undefined, configurable: true, writable: true })
    const origExec = document.execCommand
    document.execCommand = (() => false) as typeof document.execCommand
    try {
      render(<PerfOverlay />)
      await act(async () => {
        fireEvent.keyDown(window, { key: 'P', ctrlKey: true, shiftKey: true })
      })
      await act(async () => {
        perf.record('transcript.test', { durMs: 5 })
      })
      const btn = screen.getByTestId('perf-copy-report')
      await act(async () => { fireEvent.click(btn) })
      // The fallback textarea must be present and contain the report:
      const fallback = screen.getByTestId('perf-copy-fallback')
      expect(fallback.textContent).toMatch(/Clipboard blocked/)
      const ta = screen.getByTestId('perf-copy-fallback-text') as HTMLTextAreaElement
      expect(ta.value).toMatch(/# Perf report/)
      expect(ta.value).toMatch(/transcript\.test/)
      // The button label reflects the failure:
      expect(screen.getByTestId('perf-copy-report').textContent).toMatch(/Copy failed/)
    } finally {
      if (origClipboard !== undefined) {
        Object.defineProperty(navigator, 'clipboard', { value: origClipboard, configurable: true, writable: true })
      }
      document.execCommand = origExec
    }
  })
})