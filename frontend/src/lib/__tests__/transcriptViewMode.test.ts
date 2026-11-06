/**
 * Transcript view-mode preference tests.
 *
 * The transcript can show message bodies as raw markdown source or as
 * rendered HTML. The choice is a per-browser preference persisted in
 * localStorage; the loader must never throw and must fall back to the
 * default (raw — the historical behaviour) on any garbage input.
 */

import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import {
  DEFAULT_TRANSCRIPT_VIEW_MODE,
  TRANSCRIPT_VIEW_MODE_STORAGE_KEY,
  loadTranscriptViewMode,
  saveTranscriptViewMode,
  parseTranscriptViewMode,
} from '../transcriptViewMode'

describe('transcriptViewMode', () => {
  beforeEach(() => {
    localStorage.clear()
  })

  it('defaults to raw markdown (the historical transcript rendering)', () => {
    expect(DEFAULT_TRANSCRIPT_VIEW_MODE).toBe('raw')
    expect(loadTranscriptViewMode()).toBe('raw')
  })

  it('round-trips a saved mode', () => {
    saveTranscriptViewMode('rendered')
    expect(loadTranscriptViewMode()).toBe('rendered')
    expect(localStorage.getItem(TRANSCRIPT_VIEW_MODE_STORAGE_KEY)).toBe('rendered')
    saveTranscriptViewMode('raw')
    expect(loadTranscriptViewMode()).toBe('raw')
  })

  it('falls back to the default on an unknown stored value', () => {
    localStorage.setItem(TRANSCRIPT_VIEW_MODE_STORAGE_KEY, 'html-ish garbage')
    expect(loadTranscriptViewMode()).toBe('raw')
  })

  it('validates individual values', () => {
    expect(parseTranscriptViewMode('raw')).toBe('raw')
    expect(parseTranscriptViewMode('rendered')).toBe('rendered')
    expect(parseTranscriptViewMode('')).toBe('raw')
    expect(parseTranscriptViewMode(null)).toBe('raw')
    expect(parseTranscriptViewMode(42)).toBe('raw')
  })

  describe('when localStorage throws', () => {
    const original = globalThis.localStorage

    afterEach(() => {
      Object.defineProperty(globalThis, 'localStorage', {
        value: original,
        configurable: true,
        writable: true,
      })
    })

    it('never throws on read or write', () => {
      Object.defineProperty(globalThis, 'localStorage', {
        value: {
          getItem() { throw new Error('denied') },
          setItem() { throw new Error('denied') },
        },
        configurable: true,
        writable: true,
      })
      expect(() => loadTranscriptViewMode()).not.toThrow()
      expect(loadTranscriptViewMode()).toBe('raw')
      expect(() => saveTranscriptViewMode('rendered')).not.toThrow()
    })
  })
})
