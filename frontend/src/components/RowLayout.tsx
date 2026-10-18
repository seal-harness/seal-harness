import type { ReactNode } from 'react'

/** Shared geometry for every row in the sidebar's tab/session lists.
 *
 *  "Active Tabs", "Running Harnesses", "Recent Sessions", and "Archived" all
 *  render rows into the same column, so a row's title must start at the same
 *  x in every section. Each row therefore reserves the SAME leading gutter —
 *  a fixed-width index slot (the tab's single-char badge, empty for session
 *  rows) followed by a fixed-width status slot (the liveness/activity glyph,
 *  empty when a session row has nothing to show).
 *
 *  Reserving the slots rather than rendering them only when populated is what
 *  keeps titles aligned: a thinking session row that grew an inline dot
 *  sibling would otherwise push its own title right, and tab titles would
 *  drift with the width of the glyph in the status slot.
 *
 *  The slots are fixed widths, not min-widths, so a glyph's intrinsic width
 *  can never change the title's x position. */

/** Width of the leading index slot, sized for the widest single-char tab
 *  badge (0-9, a-z). */
export const ROW_INDEX_SLOT_PX = 12

/** Width of the liveness/activity status slot. Sized for the widest status
 *  glyph (● / ✕) plus a hair of slack around the 8px activity dot. */
export const ROW_STATUS_SLOT_PX = 10

/** Left indent of a row's second line, shared by tab rows and session rows so
 *  the provider/model/repo detail line sits at the same x in every section. */
export const ROW_SECOND_LINE_INDENT_PX = 24

/** The leading index slot: the tab's single-char badge, or an empty spacer on
 *  a row with no index (session rows). */
export function RowIndexSlot({
  children,
  testId,
}: {
  children?: ReactNode
  testId?: string
}) {
  return (
    <span
      data-testid="row-index-slot"
      style={{
        display: 'inline-flex',
        alignItems: 'center',
        justifyContent: 'flex-end',
        width: ROW_INDEX_SLOT_PX,
        flexShrink: 0,
      }}
    >
      <span
        className="text-xs"
        data-testid={testId}
        style={{ color: 'var(--text-faint)', width: '100%', textAlign: 'right' }}
      >
        {children}
      </span>
    </span>
  )
}

/** The leading status slot: the liveness glyph or activity dot, or an empty
 *  spacer when the row has no status to show. */
export function RowStatusSlot({ children }: { children?: ReactNode }) {
  return (
    <span
      data-testid="row-status-slot"
      style={{
        display: 'inline-flex',
        alignItems: 'center',
        justifyContent: 'center',
        width: ROW_STATUS_SLOT_PX,
        flexShrink: 0,
      }}
    >
      {children}
    </span>
  )
}
