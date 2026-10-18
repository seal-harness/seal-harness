import type { ReactNode } from 'react'

/** Shared geometry for the sidebar's tab/session rows.
 *
 *  A TAB row has two leading slots before its title: the index slot (the
 *  single-char tab number) and the status slot (the liveness/activity glyph).
 *  Both are fixed widths so a glyph's intrinsic width can never move the
 *  title — that is what keeps every tab title at the same x.
 *
 *  A SESSION row ("Recent Sessions" / "Archived") has neither: it has no tab
 *  number and no status glyph. Instead its name is inset by
 *  `ROW_SESSION_NAME_INDENT_PX` so it starts where a tab row's number starts
 *  rather than flush against the row edge. */

/** Width of the leading index slot, sized for the widest single-char tab
 *  badge (0-9, a-z). */
export const ROW_INDEX_SLOT_PX = 12

/** Left inset of a session row's name, so it starts at the same x as the tab
 *  number in an Active Tabs row.
 *
 *  The tab number is right-aligned inside its `ROW_INDEX_SLOT_PX` slot, so a
 *  digit's visible left edge sits a digit-width in from the slot's start.
 *  This inset reproduces that position as a single fixed value, which keeps
 *  the name's x independent of which glyph the tab number happens to be. */
export const ROW_SESSION_NAME_INDENT_PX = 4

/** Width of the liveness/activity status slot. Sized for the widest status
 *  glyph (● / ✕) plus a hair of slack around the 8px activity dot. */
export const ROW_STATUS_SLOT_PX = 10

/** Left indent of a row's second line (provider/model/repo detail). Shared by
 *  tab rows and session rows so the detail line sits at one x across every
 *  section — it does NOT follow the row's first line, which differs between
 *  the two (tab title vs. session name). */
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
