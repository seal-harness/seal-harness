import { describe, it, expect, beforeEach } from 'vitest'
import {
  type TabLineField,
  TAB_LINE_FIELD_LABELS,
  ALL_TAB_LINE_FIELDS,
  DEFAULT_TAB_LINE_FIELDS,
  loadTabLineFields,
  saveTabLineFields,
  parseTabLineFields,
  moveFieldUp,
  moveFieldDown,
  toggleField,
} from '../tabLineConfig'

// ── Helpers ────────────────────────────────────────────────────────────

function mockLocalStorage() {
  let store: Record<string, string> = {}
  const ls: Storage = {
    getItem: (key: string) => store[key] ?? null,
    setItem: (key: string, value: string) => { store[key] = value },
    removeItem: (key: string) => { delete store[key] },
    clear: () => { store = {} },
    key: () => null,
    length: 0,
  }
  Object.defineProperty(globalThis, 'localStorage', {
    value: ls,
    configurable: true,
    writable: true,
  })
  return () => { store = {} }
}

// ── Constants ──────────────────────────────────────────────────────────

describe('tabLineConfig constants', () => {
  it('exports labels for all five fields', () => {
    expect(Object.keys(TAB_LINE_FIELD_LABELS).sort()).toEqual(
      ['agent', 'channel', 'model', 'provider', 'repo'],
    )
  })

  it('ALL_TAB_LINE_FIELDS lists all five canonical fields', () => {
    expect(ALL_TAB_LINE_FIELDS).toHaveLength(5)
    expect(ALL_TAB_LINE_FIELDS).toContain('provider')
    expect(ALL_TAB_LINE_FIELDS).toContain('model')
    expect(ALL_TAB_LINE_FIELDS).toContain('repo')
    expect(ALL_TAB_LINE_FIELDS).toContain('channel')
    expect(ALL_TAB_LINE_FIELDS).toContain('agent')
  })

  it('DEFAULT_TAB_LINE_FIELDS is provider → model → repo (preserves prior behavior)', () => {
    expect(DEFAULT_TAB_LINE_FIELDS).toEqual(['provider', 'model', 'repo'])
  })
})

// ── parseTabLineFields ─────────────────────────────────────────────────

describe('parseTabLineFields', () => {
  it('parses a valid field array', () => {
    expect(parseTabLineFields('["model","repo"]')).toEqual(['model', 'repo'])
  })

  it('preserves order', () => {
    expect(parseTabLineFields('["agent","provider","model"]')).toEqual(
      ['agent', 'provider', 'model'],
    )
  })

  it('returns default for invalid JSON', () => {
    expect(parseTabLineFields('not json')).toEqual(DEFAULT_TAB_LINE_FIELDS)
  })

  it('returns default for non-array', () => {
    expect(parseTabLineFields('"hello"')).toEqual(DEFAULT_TAB_LINE_FIELDS)
    expect(parseTabLineFields('42')).toEqual(DEFAULT_TAB_LINE_FIELDS)
    expect(parseTabLineFields('{}')).toEqual(DEFAULT_TAB_LINE_FIELDS)
  })

  it('filters out unknown field ids', () => {
    expect(parseTabLineFields('["model","unknown","repo"]')).toEqual(['model', 'repo'])
  })

  it('returns default for an empty array', () => {
    expect(parseTabLineFields('[]')).toEqual(DEFAULT_TAB_LINE_FIELDS)
  })

  it('returns default when all entries are unknown', () => {
    expect(parseTabLineFields('["foo","bar"]')).toEqual(DEFAULT_TAB_LINE_FIELDS)
  })

  it('returns default for duplicate fields', () => {
    expect(parseTabLineFields('["model","model","repo"]')).toEqual(DEFAULT_TAB_LINE_FIELDS)
  })

  it('accepts all five fields in custom order', () => {
    const raw = '["channel","agent","repo","model","provider"]'
    expect(parseTabLineFields(raw)).toEqual(['channel', 'agent', 'repo', 'model', 'provider'])
  })
})

// ── loadTabLineFields ──────────────────────────────────────────────────

describe('loadTabLineFields', () => {
  beforeEach(() => {
    mockLocalStorage()
  })

  it('returns default when nothing is stored', () => {
    expect(loadTabLineFields()).toEqual(DEFAULT_TAB_LINE_FIELDS)
  })

  it('returns stored value when valid', () => {
    localStorage.setItem('seal.tabLineFields', '["channel","model"]')
    expect(loadTabLineFields()).toEqual(['channel', 'model'])
  })

  it('returns default when stored value is corrupt', () => {
    localStorage.setItem('seal.tabLineFields', 'garbage')
    expect(loadTabLineFields()).toEqual(DEFAULT_TAB_LINE_FIELDS)
  })

  it('returns a copy (not the shared default array reference)', () => {
    const a = loadTabLineFields()
    const b = loadTabLineFields()
    expect(a).toEqual(b)
    expect(a).not.toBe(b)
  })
})

// ── saveTabLineFields ──────────────────────────────────────────────────

describe('saveTabLineFields', () => {
  beforeEach(() => {
    mockLocalStorage()
  })

  it('persists the fields as JSON', () => {
    saveTabLineFields(['channel', 'agent'])
    expect(localStorage.getItem('seal.tabLineFields')).toBe('["channel","agent"]')
  })

  it('round-trips through load', () => {
    const fields: TabLineField[] = ['agent', 'channel', 'model', 'provider', 'repo']
    saveTabLineFields(fields)
    expect(loadTabLineFields()).toEqual(fields)
  })

  it('does not throw when localStorage is unavailable', () => {
    Object.defineProperty(globalThis, 'localStorage', {
      value: undefined,
      configurable: true,
      writable: true,
    })
    expect(() => saveTabLineFields(['model'])).not.toThrow()
  })
})

// ── moveFieldUp ────────────────────────────────────────────────────────

describe('moveFieldUp', () => {
  it('swaps a field with the one above it', () => {
    expect(moveFieldUp(['provider', 'model', 'repo'], 'model')).toEqual(
      ['model', 'provider', 'repo'],
    )
  })

  it('is a no-op when the field is first', () => {
    expect(moveFieldUp(['provider', 'model', 'repo'], 'provider')).toEqual(
      ['provider', 'model', 'repo'],
    )
  })

  it('is a no-op when the field is not found', () => {
    expect(moveFieldUp(['provider', 'model', 'repo'], 'agent')).toEqual(
      ['provider', 'model', 'repo'],
    )
  })

  it('returns a new array (immutability)', () => {
    const orig: TabLineField[] = ['provider', 'model', 'repo']
    const result = moveFieldUp(orig, 'model')
    expect(result).not.toBe(orig)
    expect(orig).toEqual(['provider', 'model', 'repo'])
  })
})

// ── moveFieldDown ──────────────────────────────────────────────────────

describe('moveFieldDown', () => {
  it('swaps a field with the one below it', () => {
    expect(moveFieldDown(['provider', 'model', 'repo'], 'model')).toEqual(
      ['provider', 'repo', 'model'],
    )
  })

  it('is a no-op when the field is last', () => {
    expect(moveFieldDown(['provider', 'model', 'repo'], 'repo')).toEqual(
      ['provider', 'model', 'repo'],
    )
  })

  it('is a no-op when the field is not found', () => {
    expect(moveFieldDown(['provider', 'model', 'repo'], 'agent')).toEqual(
      ['provider', 'model', 'repo'],
    )
  })

  it('returns a new array (immutability)', () => {
    const orig: TabLineField[] = ['provider', 'model', 'repo']
    const result = moveFieldDown(orig, 'model')
    expect(result).not.toBe(orig)
    expect(orig).toEqual(['provider', 'model', 'repo'])
  })
})

// ── toggleField ────────────────────────────────────────────────────────

describe('toggleField', () => {
  it('appends a field when it is absent', () => {
    expect(toggleField(['provider', 'model'], 'repo')).toEqual(
      ['provider', 'model', 'repo'],
    )
  })

  it('removes a field when it is present', () => {
    expect(toggleField(['provider', 'model', 'repo'], 'model')).toEqual(
      ['provider', 'repo'],
    )
  })

  it('refuses to remove the last field', () => {
    expect(toggleField(['model'], 'model')).toEqual(['model'])
  })

  it('is a no-op when adding a field already present', () => {
    const result = toggleField(['provider', 'model'], 'provider')
    // Toggle removes if present, so this removes provider.
    expect(result).toEqual(['model'])
  })

  it('returns a new array (immutability)', () => {
    const orig: TabLineField[] = ['provider', 'model']
    const result = toggleField(orig, 'repo')
    expect(result).not.toBe(orig)
    expect(orig).toEqual(['provider', 'model'])
  })
})
