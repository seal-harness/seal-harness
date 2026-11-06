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
 * All range/spacer/height math lives in `lib/transcriptScroll.ts`; this
 * hook only wires DOM measurements to those pure functions. It owns no
 * scroll-decision state:
 * - whether the user is at the bottom is an input (`atBottomRef`), owned by
 *   ChatArea's scroll listener;
 * - the programmatic-scroll guard (`scrollGuard`) is shared with ChatArea so
 *   the measurement adjustment below can never be mistaken for a user
 *   scroll (or vice versa).
 *
 * Design:
 * - The visible range is [startIndex, endIndex) — a slice of the full
 *   Message[] array.
 * - An average row height is maintained by measuring the rendered content
 *   after each visible-range change. Unrendered regions use this average
 *   for spacer height estimation.
 * - On scroll, the visible range is recalculated from scrollTop /
 *   avgRowHeight, with an overscan buffer. Scroll events are coalesced via
 *   requestAnimationFrame so multiple events within one frame produce a
 *   single range update.
 * - When avgRowHeight changes (after measuring newly-rendered content),
 *   scrollTop is adjusted by the spacer-height delta so the visible content
 *   doesn't jump. The guard suppresses that synthetic scroll event; the
 *   guard is cleared by the next non-matching (real) scroll, so a browser
 *   that coalesces or clamps the adjustment cannot deaden scrolling.
 * - When new messages arrive, the window sticks to the bottom if the user
 *   was already at the bottom; otherwise the range stays put.
 * - On session switch (resetKey change), the window resets to the bottom.
 */

import { useCallback, useEffect, useLayoutEffect, useRef, useState } from 'react'

import { rateLimitedLog, detectLoop, logMemoryNow } from '../lib/diag'
import {
  ESTIMATED_ROW_HEIGHT,
  MIN_RENDERED,
  OVERSCAN,
  blendRowHeight,
  computeSpacers,
  computeVisibleRange,
  isSyntheticScroll,
  spacerScrollAdjustment,
} from '../lib/transcriptScroll'

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

export interface VirtualWindowOptions {
  /** Whether the user is at the bottom of the transcript. Owned by the
   *  caller's scroll listener; defaults to `true` (stick to the bottom). */
  atBottomRef?: React.MutableRefObject<boolean>
  /** Expected scrollTop of an in-flight programmatic adjustment. Shared
   *  with the caller so both listeners agree on what is synthetic. */
  scrollGuard?: React.MutableRefObject<number | null>
}

export function useVirtualWindow(
  messageCount: number,
  scrollerRef: React.RefObject<HTMLDivElement>,
  /** When this value changes, the window resets to the bottom (used for
   *  session switches). */
  resetKey: string | null,
  options: VirtualWindowOptions = {},
): VirtualWindow {
  const ownAtBottomRef = useRef(true)
  const ownScrollGuardRef = useRef<number | null>(null)
  const atBottomRef = options.atBottomRef ?? ownAtBottomRef
  const scrollGuard = options.scrollGuard ?? ownScrollGuardRef

  // Initial state: render the bottom of the transcript.
  const [visibleRange, setVisibleRange] = useState<[number, number]>(() => {
    const start = Math.max(0, messageCount - MIN_RENDERED)
    return [start, messageCount]
  })

  // avgRowHeight is state (not a ref) so that updating it triggers a
  // re-render with corrected spacer heights. This is critical for scroll
  // position preservation: the scrollTop adjustment must happen in the
  // same synchronous layout phase as the spacer height change, which
  // requires both to be in the same render commit.
  const [avgRowHeight, setAvgRowHeight] = useState(ESTIMATED_ROW_HEIGHT)
  const contentRef = useRef<HTMLDivElement>(null)
  const measureCountRef = useRef(0)

  // Reset to bottom on session change.
  useEffect(() => {
    logMemoryNow(`VW.reset key=${resetKey}`)
    rateLimitedLog('VW.reset', 1000, () => `resetKey=${resetKey} msgCount=${messageCount}`)
    const start = Math.max(0, messageCount - MIN_RENDERED)
    setVisibleRange([start, messageCount])
    setAvgRowHeight(ESTIMATED_ROW_HEIGHT)
    console.log(`[vwindow] RESET resetKey=${resetKey} messageCount=${messageCount} range=[${start}, ${messageCount}]`)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [resetKey])

  // Measure rendered content height after the visible range changes and
  // update the average row height. useLayoutEffect runs after DOM commit
  // but before paint, so the measurement and scrollTop adjustment are
  // applied before the user sees anything.
  //
  // deps: [visibleRange] — only measure when the rendered content changes,
  // not on every render.
  useLayoutEffect(() => {
    const el = contentRef.current
    if (!el) return
    measureCountRef.current++
    detectLoop('VW.measure', 200, 10)
    rateLimitedLog('VW.measure', 1000, () =>
      `range=[${visibleRange[0]},${visibleRange[1]}) avgH=${avgRowHeight} rendered=${visibleRange[1] - visibleRange[0]} measured=${el.offsetHeight}`,
    )

    const renderedCount = visibleRange[1] - visibleRange[0]
    if (renderedCount <= 0) return
    const measuredHeight = el.offsetHeight
    if (measuredHeight <= 0) return
    const blendedAvg = blendRowHeight(avgRowHeight, measuredHeight, renderedCount)
    if (blendedAvg === avgRowHeight) return
    // Scroll position preservation: when avgRowHeight changes, the top
    // spacer height changes by startIndex * delta. Adjust scrollTop by
    // that delta so the visible content stays in place.
    const adjustment = spacerScrollAdjustment(visibleRange[0], avgRowHeight, blendedAvg)
    setAvgRowHeight(blendedAvg)
    const scroller = scrollerRef.current
    if (scroller && Math.abs(adjustment) >= 1) {
      const target = scroller.scrollTop + adjustment
      scrollGuard.current = target
      scroller.scrollTop = target
    }
    rateLimitedLog('VW.avgRowHeight', 2000, () =>
      `${avgRowHeight}→${blendedAvg} adjustment=${adjustment.toFixed(1)}`,
    )
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [visibleRange])

  // Recalculate the visible range from the current scroll position.
  const updateVisibleRange = useCallback(() => {
    const el = scrollerRef.current
    if (!el || messageCount === 0) return
    const { startIndex, endIndex } = computeVisibleRange({
      scrollTop: el.scrollTop,
      viewportHeight: el.clientHeight,
      avgRowHeight,
      messageCount,
      overscan: OVERSCAN,
      minRendered: MIN_RENDERED,
    })
    setVisibleRange((prev) => {
      if (prev[0] === startIndex && prev[1] === endIndex) return prev
      return [startIndex, endIndex]
    })
  }, [scrollerRef, messageCount, avgRowHeight])

  // Scroll event listener with rAF coalescing. Multiple scroll events
  // within one animation frame are coalesced into a single update. The
  // synthetic guard is cleared only by a NON-matching scroll, so the
  // caller's listener and this one cannot disarm each other.
  useEffect(() => {
    const el = scrollerRef.current
    if (!el) return
    let rafId: number | null = null
    const onScroll = () => {
      if (isSyntheticScroll(el.scrollTop, scrollGuard.current)) {
        detectLoop('VW.scroll.suppressed', 200, 10)
        rateLimitedLog('VW.scroll', 500, () =>
          `suppressed (programmatic) scrollTop=${el.scrollTop.toFixed(0)}`,
        )
        return
      }
      scrollGuard.current = null
      detectLoop('VW.scroll.real', 200, 15)
      rateLimitedLog('VW.scroll', 500, () =>
        `real scrollTop=${el.scrollTop.toFixed(0)} scrollH=${el.scrollHeight} clientH=${el.clientHeight}`,
      )
      if (rafId !== null) return
      rafId = requestAnimationFrame(() => {
        rafId = null
        updateVisibleRange()
      })
    }
    el.addEventListener('scroll', onScroll, { passive: true })
    return () => {
      el.removeEventListener('scroll', onScroll)
      if (rafId !== null) cancelAnimationFrame(rafId)
    }
  }, [scrollerRef, updateVisibleRange, scrollGuard])

  // When new messages arrive, stick to bottom or keep the current range.
  useEffect(() => {
    if (messageCount === 0) {
      rateLimitedLog('VW.msgCount', 1000, () => 'messageCount=0 — clearing range')
      setVisibleRange([0, 0])
      return
    }
    rateLimitedLog('VW.msgCount', 1000, () =>
      `messageCount=${messageCount} atBottom=${atBottomRef.current}`,
    )
    if (atBottomRef.current) {
      setVisibleRange((prev) => {
        const size = Math.max(prev[1] - prev[0], MIN_RENDERED)
        const start = Math.max(0, messageCount - size)
        return [start, messageCount]
      })
    } else {
      // Clamp the existing range to valid bounds. When a chunk replaces the
      // entries with a different count, the old range may be out of bounds.
      setVisibleRange((prev) => {
        const start = Math.min(Math.max(0, prev[0]), Math.max(0, messageCount - 1))
        const end = Math.min(Math.max(prev[1], start + 1), messageCount)
        if (prev[0] === start && prev[1] === end) return prev
        return [start, end]
      })
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [messageCount])

  const count = Math.max(0, Math.floor(messageCount))
  const startIndex = Math.min(visibleRange[0], count)
  const endIndex = Math.min(Math.max(visibleRange[1], startIndex), count)
  const { top: topSpacerHeight, bottom: bottomSpacerHeight } = computeSpacers(
    { startIndex, endIndex },
    count,
    avgRowHeight,
  )

  return {
    startIndex,
    endIndex,
    topSpacerHeight,
    bottomSpacerHeight,
    contentRef,
  }
}
