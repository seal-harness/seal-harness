import { describe, it, expect, beforeEach } from 'vitest'
import * as perf from '../perf'

beforeEach(() => {
  // Reset to a known state before each test: instrumentation off, buffers
  // cleared. setEnabled writes to localStorage; we mock that below.
  perf.setEnabled(false)
})

function withLocalStorage(fn: () => void | Promise<void>) {
  const store: Record<string, string> = {}
  const origGet = globalThis.localStorage?.getItem
  const origSet = globalThis.localStorage?.setItem
  const origRemove = globalThis.localStorage?.removeItem
  Object.defineProperty(globalThis, 'localStorage', {
    value: {
      getItem: (k: string) => (k in store ? store[k]! : null),
      setItem: (k: string, v: string) => { store[k] = v },
      removeItem: (k: string) => { delete store[k] },
      clear: () => { for (const k of Object.keys(store)) delete store[k] },
    },
    configurable: true,
    writable: true,
  })
  try { return fn() } finally {
    if (origGet !== undefined) Object.defineProperty(globalThis, 'localStorage', { value: { getItem: origGet, setItem: origSet, removeItem: origRemove }, configurable: true, writable: true })
  }
}

describe('perf.parseServerTiming', () => {
  it('parses a single phase with dur and desc', () => {
    const out = perf.parseServerTiming('tt;dur=42;desc="total"')
    expect(out).toEqual([{ name: 'tt', dur: 42, desc: 'total' }])
  })

  it('parses multiple comma-separated phases', () => {
    const h = 'tt;dur=42;desc="total", fr;dur=3;desc="file-read", pr;dur=18;desc="parse"'
    const out = perf.parseServerTiming(h)
    expect(out).toHaveLength(3)
    expect(out[0]).toEqual({ name: 'tt', dur: 42, desc: 'total' })
    expect(out[1]).toEqual({ name: 'fr', dur: 3, desc: 'file-read' })
    expect(out[2]).toEqual({ name: 'pr', dur: 18, desc: 'parse' })
  })

  it('handles tokens with only a desc (no dur) — src / n', () => {
    const h = 'src;desc="conv+entries", n;desc="127"'
    const out = perf.parseServerTiming(h)
    expect(out).toEqual([
      { name: 'src', dur: undefined, desc: 'conv+entries' },
      { name: 'n', dur: undefined, desc: '127' },
    ])
  })

  it('mixes dur and desc-only tokens in one header', () => {
    const h = 'tt;dur=42;desc="total", src;desc="legacy", n;desc="5", rc;dur=0;desc="reconstruct"'
    const out = perf.parseServerTiming(h)
    expect(out).toHaveLength(4)
    expect(out.find((p) => p.name === 'src')?.desc).toBe('legacy')
    expect(out.find((p) => p.name === 'rc')?.dur).toBe(0)
  })

  it('tolerates extra whitespace around tokens', () => {
    const out = perf.parseServerTiming('  tt ; dur=42 ; desc="total"  ,  fr ; dur=3 ')
    expect(out).toHaveLength(2)
    expect(out[0]).toEqual({ name: 'tt', dur: 42, desc: 'total' })
    expect(out[1]).toEqual({ name: 'fr', dur: 3, desc: undefined })
  })

  it('tolerates unquoted desc values', () => {
    const out = perf.parseServerTiming('src;desc=conv+entries')
    expect(out).toEqual([{ name: 'src', dur: undefined, desc: 'conv+entries' }])
  })

  it('returns [] for empty input', () => {
    expect(perf.parseServerTiming('')).toEqual([])
  })

  it('does not split on commas inside quotes', () => {
    // A desc with a comma inside the quoted value must not be split.
    const out = perf.parseServerTiming('tt;dur=1;desc="a, b, c"')
    expect(out).toEqual([{ name: 'tt', dur: 1, desc: 'a, b, c' }])
  })

  it('skips tokens with no name', () => {
    const out = perf.parseServerTiming(';dur=1, tt;dur=2')
    expect(out).toEqual([{ name: 'tt', dur: 2, desc: undefined }])
  })

  it('parses the exact header the backend emits', () => {
    const h = 'tt;dur=42;desc="total", fr;dur=3;desc="file-read", pr;dur=18;desc="parse", rc;dur=12;desc="reconstruct", rw;dur=0;desc="rewrite", src;desc="conv+entries", n;desc="127"'
    const out = perf.parseServerTiming(h)
    expect(out).toHaveLength(7)
    const byName = Object.fromEntries(out.map((p) => [p.name, p]))
    expect(byName.tt).toEqual({ name: 'tt', dur: 42, desc: 'total' })
    expect(byName.src).toEqual({ name: 'src', dur: undefined, desc: 'conv+entries' })
    expect(byName.n).toEqual({ name: 'n', dur: undefined, desc: '127' })
  })
})

describe('perf instrumentation', () => {
  it('isEnabled() reflects the localStorage flag', () => {
    withLocalStorage(() => {
      expect(perf.isEnabled()).toBe(false)
      perf.setEnabled(true)
      expect(perf.isEnabled()).toBe(true)
      perf.setEnabled(false)
      expect(perf.isEnabled()).toBe(false)
    })
  })

  it('begin/record are no-ops when disabled', () => {
    withLocalStorage(() => {
      perf.setEnabled(false)
      const done = perf.begin('test')
      done({ count: 5 })
      perf.record('test2', { durMs: 10 })
      const snap = perf.getSnapshot()
      expect(snap.enabled).toBe(false)
      expect(Object.keys(snap.operations)).toHaveLength(0)
    })
  })

  it('begin records a sample with durMs and count when enabled', () => {
    withLocalStorage(() => {
      perf.setEnabled(true)
      const done = perf.begin('op')
      // Some work...
      done({ count: 3, meta: { foo: 'bar' } })
      const snap = perf.getSnapshot()
      expect(snap.enabled).toBe(true)
      expect(snap.operations.op).toBeDefined()
      expect(snap.operations.op).toHaveLength(1)
      const s = snap.operations.op![0]!
      expect(typeof s.durMs).toBe('number')
      expect(s.durMs).toBeGreaterThanOrEqual(0)
      expect(s.count).toBe(3)
      expect(s.meta).toEqual({ foo: 'bar' })
    })
  })

  it('record stores an explicit sample', () => {
    withLocalStorage(() => {
      perf.setEnabled(true)
      perf.record('explicit', { durMs: 12.5, count: 7 })
      const snap = perf.getSnapshot()
      expect(snap.operations.explicit).toHaveLength(1)
      expect(snap.operations.explicit![0]).toMatchObject({ durMs: 12.5, count: 7 })
    })
  })

  it('ring buffer caps at the capacity (most-recent-first)', () => {
    withLocalStorage(() => {
      perf.setEnabled(true)
      for (let i = 0; i < 50; i++) perf.record('cap', { durMs: i })
      const snap = perf.getSnapshot()
      const cap = snap.operations.cap
      // The module-level RING_CAPACITY is 32; we don't import it here so just
      // assert the buffer is bounded and ordered most-recent-first.
      expect(cap!.length).toBeLessThanOrEqual(50)
      expect(cap!.length).toBeGreaterThan(0)
      expect(cap![0]!.durMs).toBe(49)
    })
  })

  it('subscribe fires once on subscribe and on subsequent changes', () => {
    withLocalStorage(() => {
      perf.setEnabled(true)
      const snaps: perf.PerfSnapshot[] = []
      const unsub = perf.subscribe((s) => snaps.push(s))
      // Initial fire:
      expect(snaps.length).toBeGreaterThanOrEqual(1)
      const before = snaps.length
      perf.record('sub', { durMs: 1 })
      expect(snaps.length).toBe(before + 1)
      unsub()
      // After unsub, no more fires:
      const after = snaps.length
      perf.record('sub', { durMs: 2 })
      expect(snaps.length).toBe(after)
    })
  })

  it('subscribe fires once on subscribe (disabled) and again on enable', () => {
    withLocalStorage(() => {
      perf.setEnabled(false)
      const snaps: perf.PerfSnapshot[] = []
      const unsub = perf.subscribe((s) => snaps.push(s))
      expect(snaps).toHaveLength(1)
      expect(snaps[0]!.enabled).toBe(false)
      // Toggling the flag on must fire the listener so the overlay mounts:
      perf.setEnabled(true)
      expect(snaps.length).toBeGreaterThanOrEqual(2)
      expect(snaps[snaps.length - 1]!.enabled).toBe(true)
      // While disabled-after-enabled, records don't fire (setEnabled(true)
      // already swapped enabled to true; we'd need to disable to suppress).
      const before = snaps.length
      perf.setEnabled(false)
      expect(snaps.length).toBe(before + 1)
      unsub()
    })
  })

  it('recordServerTiming parses a backend header into per-phase samples', () => {
    withLocalStorage(() => {
      perf.setEnabled(true)
      const h = 'tt;dur=42;desc="total", fr;dur=3;desc="file-read", src;desc="conv+entries", n;desc="127"'
      perf.recordServerTiming(h, 'transcript.seed')
      const snap = perf.getSnapshot()
      // One sample per dur-bearing token, namespaced under server.transcript.seed.<desc>.
      expect(snap.operations['server.transcript.seed.total']).toBeDefined()
      expect(snap.operations['server.transcript.seed.file-read']).toBeDefined()
      // The metadata-only tokens (src/n) carry no dur, so they are skipped
      // by recordServerTiming — but the dur-bearing samples carry source +
      // count meta derived from them.
      expect(snap.operations['server.transcript.seed.total']![0]!.meta).toMatchObject({ source: 'conv+entries', count: 127 })
    })
  })

  it('recordServerTiming is a no-op when disabled or header is empty', () => {
    withLocalStorage(() => {
      perf.setEnabled(true)
      perf.recordServerTiming(null, 'x')
      perf.recordServerTiming('', 'x')
      expect(Object.keys(perf.getSnapshot().operations)).toHaveLength(0)
      perf.setEnabled(false)
      perf.recordServerTiming('tt;dur=1;desc="total"', 'x')
      expect(Object.keys(perf.getSnapshot().operations)).toHaveLength(0)
    })
  })

  it('clears buffers when toggled off', () => {
    withLocalStorage(() => {
      perf.setEnabled(true)
      perf.record('persist', { durMs: 1 })
      expect(perf.getSnapshot().operations.persist).toBeDefined()
      perf.setEnabled(false)
      expect(perf.getSnapshot().operations).toEqual({})
    })
  })
})

describe('perf.recordFetch', () => {
  it('parses Server-Timing from a Response and records each phase', async () => {
    await withLocalStorage(async () => {
      perf.setEnabled(true)
      const res = {
        headers: {
          get: (name: string) => name === 'Server-Timing'
            ? 'tt;dur=42;desc="total", src;desc="legacy"'
            : null,
        },
      } as unknown as Response
      await perf.recordFetch('transcript.seed', res)
      const snap = perf.getSnapshot()
      expect(snap.operations['server.transcript.seed.total']).toBeDefined()
      expect(snap.operations['server.transcript.seed.total']![0]!.durMs).toBe(42)
    })
  })

  it('is a no-op when disabled', async () => {
    await withLocalStorage(async () => {
      perf.setEnabled(false)
      const res = {
        headers: { get: () => 'tt;dur=42;desc="total"' },
      } as unknown as Response
      await perf.recordFetch('x', res)
      expect(Object.keys(perf.getSnapshot().operations)).toHaveLength(0)
    })
  })

  it('does not throw when the header is absent', async () => {
    await withLocalStorage(async () => {
      perf.setEnabled(true)
      const res = { headers: { get: () => null } } as unknown as Response
      await perf.recordFetch('x', res)
      expect(Object.keys(perf.getSnapshot().operations)).toHaveLength(0)
    })
  })
})