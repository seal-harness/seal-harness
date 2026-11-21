/**
 * Pure scroll and virtual-window math.
 *
 * Everything here is a function of numbers, so it can be tested without a
 * browser and reused by both the component (ChatArea) and the virtual
 * window hook. The hook owns no scroll-decision state of its own; it feeds
 * the measurements from the DOM into these functions.
 */

export const AT_BOTTOM_PX = 80
export const AT_TOP_PX = 60
export const ESTIMATED_ROW_HEIGHT = 120
export const OVERSCAN = 50
export const MIN_RENDERED = 100

export interface ScrollMetrics {
  scrollTop: number
  scrollHeight: number
  clientHeight: number
}

export interface VisibleRange {
  startIndex: number
  endIndex: number
}

function finite(value: number): boolean {
  return Number.isFinite(value)
}

/** Distance in px between the viewport's bottom edge and the content's end. */
export function distanceFromBottom(m: ScrollMetrics): number {
  return m.scrollHeight - m.scrollTop - m.clientHeight
}

/** Whether the viewport is within `threshold` px of the bottom. */
export function isAtBottom(
  m: ScrollMetrics,
  threshold: number = AT_BOTTOM_PX,
): boolean {
  if (!finite(m.scrollTop) || !finite(m.scrollHeight) || !finite(m.clientHeight)) {
    return false
  }
  return distanceFromBottom(m) < threshold
}

/** Whether the viewport is within `threshold` px of the top. */
export function isNearTop(
  m: ScrollMetrics,
  threshold: number = AT_TOP_PX,
): boolean {
  if (!finite(m.scrollTop)) return false
  return m.scrollTop < threshold
}

export interface VisibleRangeInput {
  scrollTop: number
  viewportHeight: number
  avgRowHeight: number
  messageCount: number
  overscan: number
  minRendered: number
}

/**
 * Which message indices to render for a given scroll position, plus an
 * overscan buffer and a minimum rendered count. Always clamped to
 * `[0, messageCount]` with `startIndex <= endIndex`.
 */
export function computeVisibleRange(input: VisibleRangeInput): VisibleRange {
  const count = Math.max(0, Math.floor(input.messageCount))
  if (count === 0) return { startIndex: 0, endIndex: 0 }
  const avg =
    finite(input.avgRowHeight) && input.avgRowHeight > 0
      ? input.avgRowHeight
      : ESTIMATED_ROW_HEIGHT
  const scrollTop = finite(input.scrollTop) && input.scrollTop > 0 ? input.scrollTop : 0
  const viewportHeight =
    finite(input.viewportHeight) && input.viewportHeight > 0 ? input.viewportHeight : 0
  const overscan = Math.max(0, Math.floor(input.overscan))
  const minRendered = Math.max(0, Math.floor(input.minRendered))

  const firstVisible = Math.min(
    count,
    Math.max(0, Math.floor(scrollTop / avg) - overscan),
  )
  const lastVisible = Math.min(
    count,
    Math.max(firstVisible, Math.ceil((scrollTop + viewportHeight) / avg) + overscan),
  )
  const endIndex = Math.min(
    count,
    Math.max(lastVisible, Math.min(count, firstVisible + minRendered)),
  )
  return { startIndex: firstVisible, endIndex }
}

/** Spacer heights standing in for unrendered rows above/below. Never negative. */
export function computeSpacers(
  range: VisibleRange,
  messageCount: number,
  avgRowHeight: number,
): { top: number; bottom: number } {
  const count = Math.max(0, Math.floor(messageCount))
  const avg =
    finite(avgRowHeight) && avgRowHeight > 0 ? avgRowHeight : 0
  const start = Math.min(count, Math.max(0, Math.floor(range.startIndex)))
  const end = Math.min(count, Math.max(start, Math.floor(range.endIndex)))
  return {
    top: Math.max(0, Math.round(start * avg)),
    bottom: Math.max(0, Math.round((count - end) * avg)),
  }
}

/**
 * Blend a new per-row height measurement into the running average. The
 * conservative 85/15 blend keeps one tall or short chunk from swinging the
 * spacer estimate (and therefore the scroll position) around.
 */
export function blendRowHeight(
  previous: number,
  measuredHeight: number,
  renderedCount: number,
): number {
  if (
    !finite(previous) ||
    previous <= 0 ||
    !finite(measuredHeight) ||
    measuredHeight <= 0 ||
    !finite(renderedCount) ||
    renderedCount <= 0
  ) {
    return finite(previous) && previous > 0 ? previous : ESTIMATED_ROW_HEIGHT
  }
  const measuredAvg = measuredHeight / renderedCount
  const blended = Math.round(previous * 0.85 + measuredAvg * 0.15)
  return blended > 0 ? blended : previous
}

/**
 * How much to shift `scrollTop` when the average row height changes, so the
 * content above the viewport keeps the same size on screen.
 */
export function spacerScrollAdjustment(
  startIndex: number,
  previousAvg: number,
  nextAvg: number,
): number {
  if (!finite(startIndex) || !finite(previousAvg) || !finite(nextAvg)) return 0
  return startIndex * (nextAvg - previousAvg)
}

/**
 * Whether a scroll event at `currentScrollTop` is the echo of a
 * programmatic scroll to `expectedScrollTop` (rounded by the browser to
 * whole pixels, hence the one-pixel tolerance).
 *
 * The expectation is NOT cleared by a match: two listeners observe the same
 * event, and clearing on match would let the first listener disarm the
 * guard for the second. It is cleared by a non-matching event instead.
 */
export function isSyntheticScroll(
  currentScrollTop: number,
  expectedScrollTop: number | null,
): boolean {
  if (expectedScrollTop === null || !finite(expectedScrollTop)) return false
  if (!finite(currentScrollTop)) return false
  return Math.abs(currentScrollTop - expectedScrollTop) <= 1
}
