import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { renderHook, act } from '@testing-library/react'
import { useVirtualWindow } from '../useVirtualWindow'

type MockFn = ReturnType<typeof vi.fn>

/** Create a wrapper that provides a real ref to a mock HTMLElement. */
function makeScroller(scrollHeight = 10000, clientHeight = 600, scrollTop = 0) {
  const addEventListenerMock: MockFn = vi.fn()
  const removeEventListenerMock: MockFn = vi.fn()
  const el = {
    scrollTop,
    scrollHeight,
    clientHeight,
    addEventListener: addEventListenerMock,
    removeEventListener: removeEventListenerMock,
  } as unknown as HTMLDivElement
  const ref = { current: el } as React.RefObject<HTMLDivElement>
  return { ref, el, addEventListenerMock, removeEventListenerMock }
}

/** Advance the mock scroller's scrollTop and dispatch a scroll event.
 *  Flushes the rAF callback that the scroll listener schedules. */
function scrollTo(el: HTMLDivElement, addEventListenerMock: MockFn, scrollTop: number) {
  Object.defineProperty(el, 'scrollTop', { value: scrollTop, writable: true })
  const calls = addEventListenerMock.mock.calls
  const scrollCall = calls.find((c: unknown[]) => c[0] === 'scroll')
  if (scrollCall) {
    const listener = scrollCall[1] as () => void
    act(() => {
      listener()
      // Flush the rAF callback scheduled by the throttled scroll handler.
      vi.advanceTimersByTime(16)
    })
  }
}

describe('useVirtualWindow', () => {
  beforeEach(() => {
    vi.useFakeTimers()
  })

  afterEach(() => {
    vi.useRealTimers()
  })

  it('defaults to the bottom of the transcript on initial render', () => {
    const { ref } = makeScroller()
    const { result } = renderHook(() => useVirtualWindow(500, ref, 's1'))
    // The window should include the last messages.
    expect(result.current.endIndex).toBe(500)
    expect(result.current.startIndex).toBeLessThanOrEqual(500)
    expect(result.current.startIndex).toBeGreaterThan(0)
  })

  it('renders all messages when count is small', () => {
    const { ref } = makeScroller()
    const { result } = renderHook(() => useVirtualWindow(10, ref, 's1'))
    expect(result.current.startIndex).toBe(0)
    expect(result.current.endIndex).toBe(10)
    expect(result.current.topSpacerHeight).toBe(0)
    expect(result.current.bottomSpacerHeight).toBe(0)
  })

  it('has a top spacer when not at the start', () => {
    const { ref, el, addEventListenerMock } = makeScroller(50000, 600, 10000)
    const { result } = renderHook(() => useVirtualWindow(500, ref, 's1'))
    scrollTo(el, addEventListenerMock, 10000)
    expect(result.current.topSpacerHeight).toBeGreaterThan(0)
  })

  it('has a bottom spacer when not at the end', () => {
    const { ref, el, addEventListenerMock } = makeScroller(50000, 600, 0)
    const { result } = renderHook(() => useVirtualWindow(500, ref, 's1'))
    scrollTo(el, addEventListenerMock, 0)
    expect(result.current.bottomSpacerHeight).toBeGreaterThan(0)
  })

  it('resets to the bottom when resetKey changes (session switch)', () => {
    const { ref } = makeScroller()
    const { result, rerender } = renderHook(
      ({ resetKey }) => useVirtualWindow(500, ref, resetKey),
      { initialProps: { resetKey: 's1' } },
    )
    expect(result.current.endIndex).toBe(500)

    // Rerender with the same key — no change.
    rerender({ resetKey: 's1' })
    expect(result.current.endIndex).toBe(500)

    // Switch session — should reset to bottom.
    rerender({ resetKey: 's2' })
    expect(result.current.endIndex).toBe(500)
    expect(result.current.startIndex).toBeLessThanOrEqual(500)
  })

  it('handles zero messages', () => {
    const { ref } = makeScroller()
    const { result } = renderHook(() => useVirtualWindow(0, ref, 's1'))
    expect(result.current.startIndex).toBe(0)
    expect(result.current.endIndex).toBe(0)
    expect(result.current.topSpacerHeight).toBe(0)
    expect(result.current.bottomSpacerHeight).toBe(0)
  })

  it('handles null scroller ref gracefully', () => {
    const ref = { current: null } as React.RefObject<HTMLDivElement>
    const { result } = renderHook(() => useVirtualWindow(100, ref, 's1'))
    expect(result.current.endIndex).toBeGreaterThanOrEqual(0)
  })

  it('sticks to bottom when new messages arrive and user was at bottom', () => {
    const { ref } = makeScroller(10000, 600, 9400)
    const { result, rerender } = renderHook(
      ({ count }) => useVirtualWindow(count, ref, 's1'),
      { initialProps: { count: 500 } },
    )
    expect(result.current.endIndex).toBe(500)
    rerender({ count: 520 })
    expect(result.current.endIndex).toBe(520)
  })

  it('visible range is clamped to [0, messageCount]', () => {
    const { ref, el, addEventListenerMock } = makeScroller(100000, 600, 50000)
    const { result } = renderHook(() => useVirtualWindow(1000, ref, 's1'))
    scrollTo(el, addEventListenerMock, 50000)
    expect(result.current.startIndex).toBeGreaterThanOrEqual(0)
    expect(result.current.endIndex).toBeLessThanOrEqual(1000)
  })

  it('registers and unregisters a scroll listener on the scroller', () => {
    const { ref, addEventListenerMock, removeEventListenerMock } = makeScroller()
    const { unmount } = renderHook(() => useVirtualWindow(500, ref, 's1'))
    expect(addEventListenerMock).toHaveBeenCalledWith('scroll', expect.any(Function), { passive: true })
    unmount()
    expect(removeEventListenerMock).toHaveBeenCalledWith('scroll', expect.any(Function))
  })

  it('coalesces multiple scroll events into one range update (rAF throttle)', () => {
    const { ref, el, addEventListenerMock } = makeScroller(50000, 600, 0)
    const { result } = renderHook(() => useVirtualWindow(1000, ref, 's1'))
    // Initial: at bottom
    expect(result.current.endIndex).toBe(1000)

    // Fire multiple scroll events without flushing rAF
    const calls = addEventListenerMock.mock.calls
    const scrollCall = calls.find((c: unknown[]) => c[0] === 'scroll')
    const listener = scrollCall![1] as () => void

    act(() => {
      Object.defineProperty(el, 'scrollTop', { value: 1000, writable: true })
      listener() // schedules rAF, doesn't update yet
      Object.defineProperty(el, 'scrollTop', { value: 2000, writable: true })
      listener() // rAF already pending — this is a no-op
      Object.defineProperty(el, 'scrollTop', { value: 3000, writable: true })
      listener() // rAF already pending — this is a no-op
    })

    // Range hasn't changed yet — rAF hasn't fired
    expect(result.current.endIndex).toBe(1000)

    // Flush rAF — the last scrollTop (3000) is used
    act(() => vi.advanceTimersByTime(16))
    expect(result.current.startIndex).toBeLessThanOrEqual(1000)
  })

  it('ignores a scroll matching the shared guard and processes the next real one', () => {
    const { ref, el, addEventListenerMock } = makeScroller(50000, 600, 10000)
    const scrollGuard = { current: 10000 as number | null }
    const atBottomRef = { current: false }
    const { result } = renderHook(() =>
      useVirtualWindow(1000, ref, 's1', { atBottomRef, scrollGuard }),
    )
    const listener = addEventListenerMock.mock.calls.find((c) => c[0] === 'scroll')![1] as () => void
    const initialStart = result.current.startIndex
    act(() => {
      listener()
      vi.advanceTimersByTime(16)
    })
    // Matches the guard: treated as the measurement adjustment, ignored.
    expect(result.current.startIndex).toBe(initialStart)
    // A different position is a real scroll and updates the range.
    act(() => {
      Object.defineProperty(el, 'scrollTop', { value: 0, writable: true })
      listener()
      vi.advanceTimersByTime(16)
    })
    expect(result.current.startIndex).toBe(0)
  })

  it('injected atBottomRef controls stick-to-bottom (default true)', () => {
    const { ref } = makeScroller()
    const notAtBottom = { current: false }
    const { result, rerender } = renderHook(
      ({ count }) => useVirtualWindow(count, ref, 's1', { atBottomRef: notAtBottom }),
      { initialProps: { count: 500 } },
    )
    rerender({ count: 520 })
    expect(result.current.endIndex).toBe(500) // did not snap to the tail

    const atBottom = { current: true }
    const second = renderHook(
      ({ count }) => useVirtualWindow(count, ref, 's1', { atBottomRef: atBottom }),
      { initialProps: { count: 500 } },
    )
    second.rerender({ count: 520 })
    expect(second.result.current.endIndex).toBe(520)

    const third = renderHook(
      ({ count }) => useVirtualWindow(count, ref, 's1'),
      { initialProps: { count: 500 } },
    )
    third.rerender({ count: 520 })
    expect(third.result.current.endIndex).toBe(520) // omitted default: true
  })
})
