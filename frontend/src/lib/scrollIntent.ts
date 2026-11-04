/**
 * Pure scroll-intent reducer for the transcript viewport.
 *
 * The transcript has exactly one pending scroll intent (`'top'`, `'bottom'`,
 * or none). Every user action, content arrival, and scroll observation goes
 * through `nextScrollIntent`, so states like "both a top and a bottom were
 * requested" or "the intent was never consumed" cannot exist.
 *
 * `fetch` says which data the caller must request before the intent can be
 * satisfied; `scrollTo` says which scroll to apply now (or, for
 * `content-arrived`, right after this render's DOM commit).
 */

export type ScrollIntent = 'top' | 'bottom' | null
export type ScrollFetch = 'beginning' | 'latest' | 'older' | null
export type ScrollTarget = 'top' | 'bottom' | null

export interface ScrollStep {
  intent: ScrollIntent
  fetch: ScrollFetch
  scrollTo: ScrollTarget
}

export type ScrollEvent =
  /** The focused session changed. `preserveAnchor` is true while a URL
   *  fragment pins the view; a deep link must not be scrolled to the
   *  bottom on a session switch. */
  | { type: 'select-session'; preserveAnchor: boolean }
  /** The user clicked "Scroll to top". */
  | { type: 'scroll-to-top'; atStart: boolean }
  /** The user clicked "Scroll to bottom". */
  | { type: 'scroll-to-bottom'; atEnd: boolean }
  /** The message list changed. */
  | { type: 'content-arrived'; loading: boolean; empty: boolean; atBottom: boolean }
  /** A real (non-programmatic) scroll observation. */
  | { type: 'scrolled'; atTop: boolean; atBottom: boolean; hasNewer: boolean; canAutoLoadOlder: boolean }
  /** The user scrolled by hand; cancel any pending intent. */
  | { type: 'user-scrolled' }

const IDLE: ScrollStep = { intent: null, fetch: null, scrollTo: null }

export function nextScrollIntent(
  current: ScrollIntent,
  event: ScrollEvent,
): ScrollStep {
  switch (event.type) {
    case 'select-session':
      return event.preserveAnchor
        ? IDLE
        : { intent: 'bottom', fetch: null, scrollTo: null }

    case 'scroll-to-top':
      return event.atStart
        ? { intent: null, fetch: null, scrollTo: 'top' }
        : { intent: 'top', fetch: 'beginning', scrollTo: null }

    case 'scroll-to-bottom':
      return event.atEnd
        ? { intent: null, fetch: null, scrollTo: 'bottom' }
        : { intent: 'bottom', fetch: 'latest', scrollTo: null }

    case 'content-arrived':
      if (event.loading) return { intent: current, fetch: null, scrollTo: null }
      // Nothing to scroll to; never leave an intent pending forever.
      if (event.empty) return IDLE
      if (current === 'top') return { intent: null, fetch: null, scrollTo: 'top' }
      if (current === 'bottom') return { intent: null, fetch: null, scrollTo: 'bottom' }
      // Sticky follow: new content while already at the bottom.
      return event.atBottom
        ? { intent: null, fetch: null, scrollTo: 'bottom' }
        : IDLE

    case 'scrolled':
      if (event.atTop && event.canAutoLoadOlder) {
        return { intent: current, fetch: 'older', scrollTo: null }
      }
      if (event.atBottom && event.hasNewer) {
        return { intent: 'bottom', fetch: 'latest', scrollTo: null }
      }
      return { intent: current, fetch: null, scrollTo: null }

    case 'user-scrolled':
      return IDLE
  }
}
