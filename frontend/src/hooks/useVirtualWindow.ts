/**
 * Virtual windowing for the transcript message list.
 *
 * The transcript is append-only and can be very large (thousands of
 * messages). Rendering every message in the DOM is prohibitively slow for
 * long transcripts. This hook calculates which messages are currently
 * visible (plus an overscan buffer) so only those are rendered. Spacer
 * divs above and below stand in for unrendered messages, keeping the
 * scrollbar proportional to the full transcript length.
 *
 * Design:
 * - The visible range is [startIndex, endIndex) — a slice of the full
 *   Message[] array.
 * - An average row height is maintained by measuring the rendered content
 *   after each render. Unrendered regions use this average for spacer
 *   height estimation.
 * - On scroll, the visible range is recalculated from scrollTop /
 *   avgRowHeight, with an overscan buffer on each side.
 * - When new messages arrive (messageCount increases), the window sticks
 *   to the bottom if the user was already at the bottom; otherwise the
 *   range stays put.
 * - On session switch (resetKey change), the window resets to the bottom.
 */

import { useCallback, useEffect, useLayoutEffect, useRef, useState } from 'react'

const OVERSCAN = 50
const ESTIMATED_ROW_HEIGHT = 120
const MIN_RENDERED = 100

export interface VirtualWindow {
  /** First message index to render (inclusive). */
  startIndex: number
  /** Last message index to render (exclusive). */
  endIndex: number
  /** Height in px for the spacer div above the rendered messages. */
  topSpacerHeight: number
  /** Height in px for the spacer div below the rendered messages. */
  bottomSpacerHeight: number
  /** Ref to attach to the div wrapping the rendered messages. Used to
   *  measure actual content height and refine the average row height. */
  contentRef: React.RefObject<HTMLDivElement>
}

export function useVirtualWindow(
  messageCount: number,
  scrollerRef: React.RefObject<HTMLDivElement>,
  /** When this value changes, the window resets to the bottom (used for
   *  session switches). */
  resetKey: string | null,
): VirtualWindow {
  // Initial state: render the bottom of the transcript.
  const [visibleRange, setVisibleRange] = useState<[number, number]>(() => {
    const start = Math.max(0, messageCount - MIN_RENDERED)
    return [start, messageCount]
  })

  const avgRowHeight = useRef(ESTIMATED_ROW_HEIGHT)
  const contentRef = useRef<HTMLDivElement>(null)
  const wasAtBottom = useRef(true)
  const prevRangeRef = useRef<[number, number]>(visibleRange)

  // Reset to bottom on session change.
  useEffect(() => {
    const start = Math.max(0, messageCount - MIN_RENDERED)
    setVisibleRange([start, messageCount])
    avgRowHeight.current = ESTIMATED_ROW_HEIGHT
    wasAtBottom.current = true
    console.log(`[transcript] RANGE reset (session switch) total=${messageCount} range=[${start}, ${messageCount})`)
  }, [resetKey]) // eslint-disable-line react-hooks/exhaustive-deps

  // Measure rendered content height after every render and update the
  // average row height. useLayoutEffect runs after DOM commit but before
  // paint, so the measurement is available for the next scroll event
  // without causing a visible flash.
  useLayoutEffect(() => {
    const el = contentRef.current
    if (!el) return
    const renderedCount = visibleRange[1] - visibleRange[0]
    if (renderedCount <= 0) return
    const measuredHeight = el.offsetHeight
    if (measuredHeight > 0) {
      const newAvg = measuredHeight / renderedCount
      // Blend the new measurement with the existing average to smooth
      // out variation (a single chunk of tall messages shouldn't
      // drastically change the estimate).
      avgRowHeight.current = Math.round(
        avgRowHeight.current * 0.3 + newAvg * 0.7,
      )
    }
  }) // Run after every render — no deps.

  // Recalculate the visible range from the current scroll position.
  const updateVisibleRange = useCallback(() => {
    const el = scrollerRef.current
    if (!el || messageCount === 0) return

    const scrollTop = el.scrollTop
    const viewportHeight = el.clientHeight
    const avg = avgRowHeight.current

    const firstVisible = Math.max(0, Math.floor(scrollTop / avg) - OVERSCAN)
    const lastVisible = Math.min(
      messageCount,
      Math.ceil((scrollTop + viewportHeight) / avg) + OVERSCAN,
    )

    // Ensure at least MIN_RENDERED messages are rendered.
    const rangeSize = lastVisible - firstVisible
    const ensuredEnd = Math.min(
      messageCount,
      firstVisible + Math.max(rangeSize, MIN_RENDERED),
    )

    setVisibleRange((prev) => {
      if (prev[0] === firstVisible && prev[1] === ensuredEnd) return prev
      return [firstVisible, ensuredEnd]
    })

    wasAtBottom.current =
      el.scrollHeight - el.scrollTop - el.clientHeight < 80
  }, [scrollerRef, messageCount])

  // Scroll event listener.
  useEffect(() => {
    const el = scrollerRef.current
    if (!el) return
    const onScroll = () => updateVisibleRange()
    el.addEventListener('scroll', onScroll, { passive: true })
    return () => el.removeEventListener('scroll', onScroll)
  }, [scrollerRef, updateVisibleRange])

  // When new messages arrive, stick to bottom or keep the current range.
  useEffect(() => {
    if (messageCount === 0) {
      setVisibleRange([0, 0])
      return
    }
    if (wasAtBottom.current) {
      // Extend the window to include new messages at the bottom.
      setVisibleRange((prev) => {
        const size = Math.max(prev[1] - prev[0], MIN_RENDERED)
        const start = Math.max(0, messageCount - size)
        return [start, messageCount]
      })
    }
    // If not at bottom, the existing range is still valid — the new
    // messages are below the viewport and will be rendered when the
    // user scrolls down. But the bottom spacer height changes, which
    // is handled by the spacer calculation below.
  }, [messageCount]) // eslint-disable-line react-hooks/exhaustive-deps

  // Log all visible-range changes for debugging. Captures scroll-driven,
  // new-message-driven, and session-switch-driven transitions in one
  // place. Search console for `[transcript] RANGE` to filter.
  useEffect(() => {
    const prev = prevRangeRef.current
    const [cur0, cur1] = visibleRange
    if (prev[0] === cur0 && prev[1] === cur1) return
    const enteredTop = cur0 < prev[0] ? `[${cur0}, ${prev[0]})` : null
    const enteredBot = cur1 > prev[1] ? `[${prev[1]}, ${cur1})` : null
    const leftTop = prev[0] < cur0 ? `[${prev[0]}, ${cur0})` : null
    const leftBot = prev[1] > cur1 ? `[${cur1}, ${prev[1]})` : null
    const parts: string[] = [`range=[${cur0}, ${cur1}) total=${messageCount}`]
    if (enteredTop) parts.push(`+top ${enteredTop}`)
    if (enteredBot) parts.push(`+bot ${enteredBot}`)
    if (leftTop) parts.push(`-top ${leftTop}`)
    if (leftBot) parts.push(`-bot ${leftBot}`)
    console.log(`[transcript] RANGE ${parts.join(' ')}`)
    prevRangeRef.current = [cur0, cur1]
  }, [visibleRange, messageCount])

  const [startIndex, endIndex] = visibleRange
  const avg = avgRowHeight.current
  const topSpacerHeight = Math.round(startIndex * avg)
  const bottomSpacerHeight = Math.round((messageCount - endIndex) * avg)

  return {
    startIndex,
    endIndex,
    topSpacerHeight,
    bottomSpacerHeight,
    contentRef,
  }
}
