// The sidebar's tab-status indicator derives a 3-state liveness from the
// per-session activity stream + the backing session's last-user-message
// timestamp:
//
//   1. Thinking    — the LLM is actively processing (activity.harness ===
//                    'thinking').
//   2. Idle Unread — the LLM is NOT thinking, the last message was from the
//                    LLM, and the user has NOT seen it. "Seen" = the user
//                    focused the session in the web UI (clearUnread-on-focus),
//                    OR the backend reported the last assistant reply was
//                    delivered to a subscribed chat channel (reply-delivered
//                    activity). Formally: the last assistant entry's
//                    timestamp (activity.lastEntryAt) is strictly newer than
//                    the seen timestamp (activity.seenAt).
//   3. Idle Read   — the LLM is NOT thinking and the user has seen the last
//                    assistant message (seenAt >= lastEntryAt, OR there is no
//                    last assistant entry).
//
// Tabs whose backing session has no activity state yet default to Idle
// Read (no unread evidence) so a freshly-loaded sidebar never flashes every
// tab as Unread before the first WS frame arrives.
//
// Sort order within the Active Tabs list (newest first within each bucket):
//   1. Idle Unread
//   2. Idle Read
//   3. Thinking
// Within each bucket, tabs sort newest → oldest by the last USER message
// timestamp (session.lastUserMessageAt), falling back to session.lastActive
// then session.createdAt so a tab always has a stable sort key.

import type { SessionInfo, TabInfo } from '../types'
import type { SessionActivityState } from '../types/stream'

/** Format an ISO timestamp as a coarse "age" pill: "now" / "Nm" / "Nh" / "Nd".
 *  Shared by the Recent Sessions rows and the Active Tabs age pill so both
 *  surfaces agree on the rendering. Returns an empty string for a missing
 *  or unparseable timestamp (the caller renders no pill in that case). */
export function formatAge(isoDate: string | null | undefined): string {
  if (!isoDate) return ''
  const ms = Date.parse(isoDate)
  if (Number.isNaN(ms)) return ''
  const diff = Date.now() - ms
  const mins = Math.floor(diff / 60000)
  if (mins < 1) return 'now'
  if (mins < 60) return `${mins}m`
  const hours = Math.floor(mins / 60)
  if (hours < 24) return `${hours}h`
  const days = Math.floor(hours / 24)
  return `${days}d`
}

export type TabStatusKind = 'thinking' | 'idle-unread' | 'idle-read'

/** The display order of the three buckets in the Active Tabs list. */
const BUCKET_ORDER: Record<TabStatusKind, number> = {
  'idle-unread': 0,
  'idle-read': 1,
  'thinking': 2,
}

/** Derive the 3-state tab status from the activity state. `activity` is
 *  optional because not every tab has a backing session with tracked
 *  activity (e.g. a shell tab, or before the first WS frame arrives). */
export function deriveTabStatusKind(
  activity: SessionActivityState | undefined,
): TabStatusKind {
  if (activity?.harness === 'thinking') return 'thinking'
  // Idle Unread requires evidence of an unseen assistant entry: a last
  // entry timestamp strictly newer than the seen timestamp. Without
  // activity, or without a lastEntryAt, default to Idle Read.
  const lastEntryAt = activity?.lastEntryAt ?? null
  const seenAt = activity?.seenAt ?? null
  if (lastEntryAt === null) return 'idle-read'
  if (seenAt === null) return 'idle-unread'
  return Date.parse(lastEntryAt) > Date.parse(seenAt) ? 'idle-unread' : 'idle-read'
}

/** Resolve the last-user-message timestamp used to sort a tab within its
 *  bucket. Falls back to lastActive then createdAt so every tab has a
 *  stable key; `null` only when the session is missing entirely (treated
 *  as oldest). */
export function tabSortTimestamp(
  session: SessionInfo | null | undefined,
): number {
  if (!session) return 0
  const ts = session.lastUserMessageAt ?? session.lastActive ?? session.createdAt
  const ms = Date.parse(ts)
  return Number.isNaN(ms) ? 0 : ms
}

/** Comparator implementing the Active Tabs sort: bucket order first
 *  (idle-unread → idle-read → thinking), then oldest last-user-message
 *  first within each bucket. Stable on ties (preserves source order). */
export function compareTabs(
  a: { tab: TabInfo; session: SessionInfo | null | undefined; activity: SessionActivityState | undefined },
  b: { tab: TabInfo; session: SessionInfo | null | undefined; activity: SessionActivityState | undefined },
): number {
  const ba = BUCKET_ORDER[deriveTabStatusKind(a.activity)]
  const bb = BUCKET_ORDER[deriveTabStatusKind(b.activity)]
  if (ba !== bb) return ba - bb
  return tabSortTimestamp(b.session) - tabSortTimestamp(a.session)
}

/** Sort a list of tabs by the Active Tabs precedence. Each entry pairs the
 *  tab with its backing session + activity state so the comparator has what
 *  it needs. Returns a new array (does not mutate the input). */
export function sortTabsForSidebar(
  entries: Array<{ tab: TabInfo; session: SessionInfo | null | undefined; activity: SessionActivityState | undefined }>,
): TabInfo[] {
  return [...entries].sort(compareTabs).map((e) => e.tab)
}
