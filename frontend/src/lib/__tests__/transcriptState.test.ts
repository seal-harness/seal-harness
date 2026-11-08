import { describe, it, expect } from 'vitest'
import type { TranscriptEntry } from '../../types'
import {
  INITIAL_TRANSCRIPT_STATE,
  WHOLE_EXTENT,
  reduceTranscript,
  hasOlder,
  isViewingLatest,
  canAutoLoadOlder,
  type TranscriptEvent,
  type TranscriptState,
  type WindowExtent,
} from '../transcriptState'

function makeEntry(id: string, ts = '2026-01-01T00:00:00Z', payload = 'hi'): TranscriptEntry {
  return {
    id,
    timestamp: ts,
    direction: 'response',
    payload,
    harness: null,
    model: 'm',
    channel: null,
    userId: null,
    internal: null,
    raw: '{}',
  }
}

function makeEntries(prefix: string, count: number, start = 0): TranscriptEntry[] {
  return Array.from({ length: count }, (_, i) => makeEntry(`${prefix}-${start + i}`))
}

const run = (state: TranscriptState, ...events: TranscriptEvent[]): TranscriptState =>
  events.reduce(reduceTranscript, state)

describe('transcriptState reducer', () => {
  it('starts empty and whole', () => {
    expect(INITIAL_TRANSCRIPT_STATE.entries).toEqual([])
    expect(INITIAL_TRANSCRIPT_STATE.extent).toEqual(WHOLE_EXTENT)
    expect(hasOlder(INITIAL_TRANSCRIPT_STATE.extent)).toBe(false)
    expect(isViewingLatest(INITIAL_TRANSCRIPT_STATE.extent)).toBe(true)
  })

  it('seeds the tail window with older entries available', () => {
    const state = run(INITIAL_TRANSCRIPT_STATE, {
      type: 'seed',
      entries: makeEntries('e', 50, 950),
      chunkHasMore: true,
    })
    expect(state.entries).toHaveLength(50)
    expect(hasOlder(state.extent)).toBe(true)
    expect(isViewingLatest(state.extent)).toBe(true)
    expect(canAutoLoadOlder(state.extent)).toBe(true)
  })

  it('seeds a complete transcript as both atStart and atEnd', () => {
    const state = run(INITIAL_TRANSCRIPT_STATE, {
      type: 'seed',
      entries: makeEntries('e', 40),
      chunkHasMore: false,
    })
    expect(state.extent).toEqual({ atStart: true, atEnd: true, olderBlocked: false })
  })

  it('chunk-latest replaces entries and marks both edges', () => {
    const state = run(
      INITIAL_TRANSCRIPT_STATE,
      { type: 'seed', entries: makeEntries('e', 50, 950), chunkHasMore: true },
      { type: 'chunk-latest', entries: makeEntries('e', 50, 950), chunkHasMore: true },
    )
    expect(isViewingLatest(state.extent)).toBe(true)
    expect(hasOlder(state.extent)).toBe(true)
  })

  it('a prepend with more entries keeps hasOlder true', () => {
    const state = run(
      INITIAL_TRANSCRIPT_STATE,
      { type: 'seed', entries: makeEntries('e', 50, 950), chunkHasMore: true },
      { type: 'chunk-older', entries: makeEntries('e', 50, 900), chunkHasMore: true },
    )
    expect(state.entries).toHaveLength(100)
    expect(state.entries[0]!.id).toBe('e-900')
    expect(hasOlder(state.extent)).toBe(true)
  })

  it('the final prepend (no entries before it) marks atStart', () => {
    const state = run(
      INITIAL_TRANSCRIPT_STATE,
      { type: 'seed', entries: makeEntries('e', 50, 50), chunkHasMore: true },
      { type: 'chunk-older', entries: makeEntries('e', 50, 0), chunkHasMore: false },
    )
    expect(hasOlder(state.extent)).toBe(false)
    // The window now covers the whole transcript, so it is at the end too.
    expect(isViewingLatest(state.extent)).toBe(true)
    expect(canAutoLoadOlder(state.extent)).toBe(false)
  })

  it('preserves the existing 1-entry-prepend semantics (hasMore:false at the start)', () => {
    const state = run(
      INITIAL_TRANSCRIPT_STATE,
      { type: 'seed', entries: makeEntries('e', 1, 5), chunkHasMore: true },
      { type: 'chunk-older', entries: makeEntries('e', 1, 4), chunkHasMore: false },
    )
    expect(hasOlder(state.extent)).toBe(false)
  })

  it('dedupes a prepend that was already delivered by the live tail', () => {
    const state = run(
      INITIAL_TRANSCRIPT_STATE,
      { type: 'seed', entries: makeEntries('e', 2, 10), chunkHasMore: true },
      { type: 'entry', entry: makeEntry('e-9') },
      { type: 'chunk-older', entries: [makeEntry('e-8'), makeEntry('e-9')], chunkHasMore: true },
    )
    // The prepend goes before the existing window; the live-tail entry is
    // deduped (it is NOT re-inserted in positional order — the view is
    // append-only by design).
    expect(state.entries.filter((e) => e.id === 'e-9')).toHaveLength(1)
    expect(state.entries[0]!.id).toBe('e-8')
    expect(state.entries.map((e) => e.id)).toContain('e-10')
  })

  it('an empty older chunk blocks auto-load without marking atStart', () => {
    const blocked = run(
      INITIAL_TRANSCRIPT_STATE,
      { type: 'seed', entries: makeEntries('e', 50, 950), chunkHasMore: true },
      { type: 'chunk-older', entries: [], chunkHasMore: true },
    )
    expect(hasOlder(blocked.extent)).toBe(true)
    expect(blocked.extent.atStart).toBe(false)
    expect(canAutoLoadOlder(blocked.extent)).toBe(false)

    // A later chunk that actually adds entries clears the block.
    const recovered = reduceTranscript(blocked, {
      type: 'chunk-older',
      entries: makeEntries('e', 50, 900),
      chunkHasMore: true,
    })
    expect(canAutoLoadOlder(recovered.extent)).toBe(true)
  })

  it('a duplicate-only older chunk blocks auto-load (no progress with this cursor)', () => {
    const base = run(
      INITIAL_TRANSCRIPT_STATE,
      { type: 'seed', entries: makeEntries('e', 2, 10), chunkHasMore: true },
    )
    const state = reduceTranscript(base, {
      type: 'chunk-older',
      entries: [makeEntry('e-10'), makeEntry('e-11')],
      chunkHasMore: true,
    })
    expect(state.entries).toHaveLength(2)
    expect(canAutoLoadOlder(state.extent)).toBe(false)
    expect(hasOlder(state.extent)).toBe(true)
  })

  it('an empty older chunk does not change atStart even when hasMore is false', () => {
    const state = run(
      INITIAL_TRANSCRIPT_STATE,
      { type: 'seed', entries: makeEntries('e', 50, 950), chunkHasMore: true },
      { type: 'chunk-older', entries: [], chunkHasMore: false },
    )
    expect(state.extent.atStart).toBe(false)
    expect(hasOlder(state.extent)).toBe(true)
  })

  it('a beginning chunk marks atStart and keeps atEnd false when newer entries exist', () => {
    const state = run(INITIAL_TRANSCRIPT_STATE, {
      type: 'chunk-beginning',
      entries: makeEntries('e', 50),
      chunkHasMore: true,
    })
    expect(state.extent.atStart).toBe(true)
    expect(state.extent.atEnd).toBe(false)
    expect(hasOlder(state.extent)).toBe(false)
    expect(isViewingLatest(state.extent)).toBe(false)
  })

  it('a beginning chunk that is the whole transcript marks atEnd', () => {
    const state = run(INITIAL_TRANSCRIPT_STATE, {
      type: 'chunk-beginning',
      entries: makeEntries('e', 1),
      chunkHasMore: false,
    })
    expect(state.extent.atEnd).toBe(true)
    expect(isViewingLatest(state.extent)).toBe(true)
  })

  it('a live append does not move the window edges', () => {
    const beginning = run(INITIAL_TRANSCRIPT_STATE, {
      type: 'chunk-beginning',
      entries: makeEntries('e', 2),
      chunkHasMore: true,
    })
    const withLive = reduceTranscript(beginning, { type: 'entry', entry: makeEntry('e-99') })
    expect(withLive.entries).toHaveLength(3)
    expect(withLive.extent.atEnd).toBe(false)
    expect(isViewingLatest(withLive.extent)).toBe(false)
  })

  it('a streaming replacement keeps the length and the extent', () => {
    const streaming = { ...makeEntry('streaming'), streaming: true }
    const base = run(
      INITIAL_TRANSCRIPT_STATE,
      { type: 'seed', entries: [makeEntry('e-1'), streaming], chunkHasMore: true },
    )
    const finalized = reduceTranscript(base, { type: 'entry', entry: makeEntry('real-1') })
    expect(finalized.entries).toHaveLength(2)
    expect(finalized.entries[1]!.id).toBe('real-1')
    expect(finalized.extent).toEqual(base.extent)
  })

  it('merge-tail adds entries without moving the window edges', () => {
    const base = run(
      INITIAL_TRANSCRIPT_STATE,
      { type: 'seed', entries: makeEntries('e', 2), chunkHasMore: false },
    )
    const merged = reduceTranscript(base, {
      type: 'merge-tail',
      entries: [makeEntry('e-2'), makeEntry('e-3')],
    })
    expect(merged.entries.map((e) => e.id)).toEqual(['e-0', 'e-1', 'e-2', 'e-3'])
    expect(merged.extent).toEqual(base.extent)
  })

  it('chunk-error leaves state untouched', () => {
    const base = run(INITIAL_TRANSCRIPT_STATE, {
      type: 'seed',
      entries: makeEntries('e', 2),
      chunkHasMore: true,
    })
    expect(reduceTranscript(base, { type: 'chunk-error' })).toBe(base)
  })

  it('hydrate restores a beginning-only window exactly', () => {
    const extent: WindowExtent = { atStart: true, atEnd: false, olderBlocked: false }
    const state = reduceTranscript(INITIAL_TRANSCRIPT_STATE, {
      type: 'hydrate',
      entries: makeEntries('e', 3),
      extent,
    })
    expect(state.extent).toEqual(extent)
    expect(isViewingLatest(state.extent)).toBe(false)
  })

  it('reset returns to the initial state', () => {
    const dirty = run(INITIAL_TRANSCRIPT_STATE, {
      type: 'seed',
      entries: makeEntries('e', 5),
      chunkHasMore: true,
    })
    expect(reduceTranscript(dirty, { type: 'reset' })).toEqual(INITIAL_TRANSCRIPT_STATE)
  })
})
