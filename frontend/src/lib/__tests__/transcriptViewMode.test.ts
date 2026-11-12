/**
 * Transcript view-mode preference tests.
 *
 * The transcript can show message bodies as raw markdown source or as
 * rendered HTML. The choice is a per-browser preference persisted in
 * localStorage; the loader must never throw and must fall back to the
 * default (rendered — tables and lists read far better formatted) on any
 * garbage input.
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

  it('defaults to rendered markdown', () => {
    expect(DEFAULT_TRANSCRIPT_VIEW_MODE).toBe('rendered')
    expect(loadTranscriptViewMode()).toBe('rendered')
  })

  it('round-trips a saved mode', () => {
    saveTranscriptViewMode('raw')
    expect(loadTranscriptViewMode()).toBe('raw')
    expect(localStorage.getItem(TRANSCRIPT_VIEW_MODE_STORAGE_KEY)).toBe('raw')
    saveTranscriptViewMode('rendered')
    expect(loadTranscriptViewMode()).toBe('rendered')
  })

  it('honours an explicit stored "raw" even though the default is rendered', () => {
    localStorage.setItem(TRANSCRIPT_VIEW_MODE_STORAGE_KEY, 'raw')
    expect(loadTranscriptViewMode()).toBe('raw')
  })

  it('falls back to the default on an unknown stored value', () => {
    localStorage.setItem(TRANSCRIPT_VIEW_MODE_STORAGE_KEY, 'html-ish garbage')
    expect(loadTranscriptViewMode()).toBe('rendered')
  })

  it('validates individual values', () => {
    expect(parseTranscriptViewMode('raw')).toBe('raw')
    expect(parseTranscriptViewMode('rendered')).toBe('rendered')
    expect(parseTranscriptViewMode('')).toBe('rendered')
    expect(parseTranscriptViewMode(null)).toBe('rendered')
    expect(parseTranscriptViewMode(42)).toBe('rendered')
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
      expect(loadTranscriptViewMode()).toBe('rendered')
      expect(() => saveTranscriptViewMode('raw')).not.toThrow()
    })
  })
})
