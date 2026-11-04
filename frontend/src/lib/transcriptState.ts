/**
 * Pure transcript state: the loaded entry window and its extent.
 *
 * The transcript is append-only and entries arrive through a small set of
 * events (HTTP seed, WS chunks, live tail, re-seed merge, errors). Every
 * transition is a pure function so the scroll/pagination state cannot drift
 * into a stuck "there is nothing above me" state: `hasOlder` is derived from
 * the window's `atStart` flag, which is only set by a chunk that actually
 * reached the start.
 *
 * Design:
 * - `entries` and `extent` live in ONE state object. A prepend changes both,
 *   and the net number of added entries is only knowable inside the same
 *   transition (dedup with the live tail can make a chunk add nothing).
 * - `atStart` means "no entries exist before this window".
 * - `atEnd` means "this window includes the tail of the transcript".
 * - `olderBlocked` is a no-progress guard: a request that added nothing
 *   (stale cursor / rebuilt transcript) must not be re-fired automatically.
 *   An explicit "scroll to top" still asks the server for the beginning.
 * - `totalCount` is deliberately absent. The backend's count is a
 *   record/line count on the indexed path and can exceed the number of
 *   frontend entries, so it is not a sound basis for index arithmetic.
 */

import type { TranscriptEntry } from '../types'
import * as perf from './perf'

export interface WindowExtent {
  /** No entries exist before the first loaded entry. */
  atStart: boolean
  /** The loaded entries include the newest entry of the transcript. */
  atEnd: boolean
  /** The last older-chunk request added nothing; do not auto-retry it. */
  olderBlocked: boolean
}

export interface TranscriptState {
  entries: TranscriptEntry[]
  extent: WindowExtent
}

export const WHOLE_EXTENT: WindowExtent = {
  atStart: true,
  atEnd: true,
  olderBlocked: false,
}

export const INITIAL_TRANSCRIPT_STATE: TranscriptState = {
  entries: [],
  extent: WHOLE_EXTENT,
}

export type TranscriptEvent =
  | { type: 'reset' }
  /** Cache hit: restore a previously computed state verbatim. */
  | { type: 'hydrate'; entries: TranscriptEntry[]; extent: WindowExtent }
  /** HTTP seed: the last `limit` entries. */
  | { type: 'seed'; entries: TranscriptEntry[]; chunkHasMore: boolean }
  /** WS `request-entries` with `before=null`: the latest entries. */
  | { type: 'chunk-latest'; entries: TranscriptEntry[]; chunkHasMore: boolean }
  /** WS `request-entries` with `before="__beginning__"`: the oldest entries. */
  | { type: 'chunk-beginning'; entries: TranscriptEntry[]; chunkHasMore: boolean }
  /** WS `request-entries` with a `before` cursor: prepend older entries. */
  | { type: 'chunk-older'; entries: TranscriptEntry[]; chunkHasMore: boolean }
  /** Live tail: one entry (new, updated, or a finalized streaming row). */
  | { type: 'entry'; entry: TranscriptEntry }
  /** Consistency re-seed after a turn: merge new tail entries, don't move edges. */
  | { type: 'merge-tail'; entries: TranscriptEntry[] }
  /** The `entries-chunk` error frame carries no `hasMore`; nothing to learn. */
  | { type: 'chunk-error' }

/** Whether older entries exist outside the loaded window. */
export function hasOlder(extent: WindowExtent): boolean {
  return !extent.atStart
}

/** Whether the loaded window includes the newest transcript entry. */
export function isViewingLatest(extent: WindowExtent): boolean {
  return extent.atEnd
}

/** Whether an automatic near-top scroll may request older entries. */
export function canAutoLoadOlder(extent: WindowExtent): boolean {
  return !extent.atStart && !extent.olderBlocked
}

/**
 * Pure reconciler: insert `incoming` into `existing`, dedup by id.
 * Append-only — new entries (by id) are always appended at the end; existing
 * entries (id match, e.g. streaming updates) are replaced in place. This
 * guarantees that nothing already rendered shifts position when a new entry
 * arrives — the transcript view is a pure append-only function of the
 * transcript.
 *
 * When `incoming` is a finalized entry (no `streaming` flag), any prior
 * `streaming: true` placeholder is replaced in place first — the streaming
 * placeholder (id `"streaming"`) uses a sentinel id that won't match the
 * final entry's positional id, so without this the placeholder would linger
 * as a duplicate row alongside the real entry.
 *
 * The initial HTTP seed provides entries in their final on-disk order; WS
 * events arrive in append order. Append-only is correct because the backend
 * writes entries sequentially and the seed is already sorted.
 */
export function reconcileEntries(
  existing: TranscriptEntry[],
  incoming: TranscriptEntry,
): TranscriptEntry[] {
  const done = perf.begin('reconcileEntries')
  if (!incoming.streaming) {
    const streamingIdx = existing.findIndex((e) => e.streaming)
    if (streamingIdx !== -1) {
      // Replace the streaming placeholder in place regardless of id, so the
      // array position (and therefore the React key) stays stable.
      const next = existing.slice()
      next[streamingIdx] = incoming
      done({ count: existing.length, meta: { mode: 'replace-streaming' } })
      return next
    }
  }
  for (let i = 0; i < existing.length; i++) {
    if (existing[i]!.id === incoming.id) {
      const next = existing.slice()
      next[i] = incoming
      done({ count: existing.length, meta: { mode: 'replace' } })
      return next
    }
  }
  const next = existing.slice()
  next.push(incoming)
  done({ count: existing.length, meta: { mode: 'insert' } })
  return next
}

/** Prepend older chunk entries to the existing array, dedup by id.
 *  Older entries that already exist (e.g. delivered via live tail during the
 *  chunk request) are NOT re-added — the existing entry wins. Ascending
 *  order preserved: the chunk is ascending and goes before `existing`. */
export function prependChunkEntries(
  existing: TranscriptEntry[],
  older: TranscriptEntry[],
): TranscriptEntry[] {
  const existingIds = new Set(existing.map((e) => e.id))
  const deduped = older.filter((e) => !existingIds.has(e.id))
  return [...deduped, ...existing]
}

/** Pure state transition for every transcript write. */
export function reduceTranscript(
  state: TranscriptState,
  event: TranscriptEvent,
): TranscriptState {
  switch (event.type) {
    case 'reset':
      return INITIAL_TRANSCRIPT_STATE

    case 'hydrate':
      return { entries: event.entries, extent: event.extent }

    case 'seed':
    case 'chunk-latest':
      return {
        entries: event.entries,
        extent: { atStart: !event.chunkHasMore, atEnd: true, olderBlocked: false },
      }

    case 'chunk-beginning':
      return {
        entries: event.entries,
        extent: { atStart: true, atEnd: !event.chunkHasMore, olderBlocked: false },
      }

    case 'chunk-older': {
      const entries = prependChunkEntries(state.entries, event.entries)
      const added = entries.length - state.entries.length
      if (added > 0) {
        return {
          entries,
          extent: { ...state.extent, atStart: !event.chunkHasMore, olderBlocked: false },
        }
      }
      // An EMPTY chunk teaches us nothing about the start (the cursor may
      // have been stale), but it must not be fired again automatically. A
      // non-empty chunk whose entries were all already delivered by the
      // live tail carries no edge information either, but it is not a
      // no-progress request, so it does not block the next attempt.
      if (event.entries.length === 0 && !state.extent.olderBlocked) {
        return { entries, extent: { ...state.extent, olderBlocked: true } }
      }
      return { entries, extent: state.extent }
    }

    case 'entry': {
      const entries = reconcileEntries(state.entries, event.entry)
      return { entries, extent: state.extent }
    }

    case 'merge-tail': {
      let entries = state.entries
      for (const entry of event.entries) entries = reconcileEntries(entries, entry)
      return { entries, extent: state.extent }
    }

    case 'chunk-error':
      return state
  }
}
