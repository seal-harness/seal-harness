/**
 * Lightweight performance instrumentation for the transcript hot paths.
 *
 * Three complementary mechanisms, all OFF by default (gated by the
 * `seal.perf` localStorage flag) so production builds pay zero overhead:
 *
 *   1. `mark`/`measure` wrappers around `performance.mark` + `performance.measure`
 *      — these flow into the browser's standard Performance timeline, so
 *      DevTools' Performance panel and `performance.getEntriesByName`
 *      surface them with no extra wiring.
 *   2. `record` — an in-memory ring buffer of the last N timings per named
 *      operation, exposed to the debug overlay (and via `getSnapshot()` for
 *      programmatic consumers). Each record carries `durMs`, an optional
 *      `count` (entries processed), and arbitrary string `meta`.
 *   3. `parseServerTiming` — parses the `Server-Timing` response header
 *      emitted by `GET /api/sessions/:id/transcript` into the same ring
 *      buffer so backend phase timings (file-read / parse / reconstruct /
 *      rewrite / total + source + entry count) live alongside the frontend
 *      measurements in one place.
 *
 * Usage:
 *   const done = perf.begin('transcriptToMessages')
 *   ...work...
 *   done({ count: entries.length })
 *
 *   perf.recordFetch('GET /transcript', response, { count: entries.length })
 *
 * The overlay (see `components/PerfOverlay.tsx`) reads `perf.getSnapshot()`
 * on a 250ms interval and renders the last N samples per operation. Toggle
 * it with Ctrl+Shift+P (configurable). All instrumentation is a no-op when
 * the `seal.perf` localStorage flag is unset, so production builds are
 * unaffected.
 *
 * @module
 */

const STORAGE_KEY = 'seal.perf'
const RING_CAPACITY = 32

export interface PerfSample {
  /** Wall-clock duration in milliseconds (rounded to 0.01ms). 0 for events
   *  that carry only metadata (e.g. a parsed Server-Timing `src`/`n` token
   *  with no `dur`). */
  durMs: number
  /** Number of items processed in this operation (e.g. transcript entry
   *  count). Undefined when not applicable. */
  count?: number
  /** Free-form metadata (e.g. `{ source: 'conv+entries' }` from a parsed
   *  Server-Timing header, or `{ sessionId }` from a fetch). */
  meta?: Record<string, string | number | undefined>
  /** When the sample was recorded (epoch ms). */
  at: number
}

export interface PerfSnapshot {
  /** Map from operation name to its ring buffer (most-recent-first). */
  operations: Record<string, PerfSample[]>
  /** Whether instrumentation is currently enabled. */
  enabled: boolean
}

let enabled = false
let buffers: Map<string, PerfSample[]> = new Map()
let listeners: Set<(snap: PerfSnapshot) => void> = new Set()

function readEnabled(): boolean {
  if (typeof localStorage === 'undefined') return false
  try {
    return localStorage.getItem(STORAGE_KEY) === '1'
  } catch {
    return false
  }
}

function refreshEnabled(): void {
  const was = enabled
  enabled = readEnabled()
  // Clear buffers when toggled off so a stale snapshot doesn't linger.
  if (was && !enabled) buffers = new Map()
}

// Read the initial flag once at module load. The overlay is responsible for
// re-reading on toggle (it calls `setEnabled` directly).
refreshEnabled()

/** Returns whether instrumentation is currently active. */
export function isEnabled(): boolean {
  return enabled
}

/** Toggle instrumentation on/off. Writes the `seal.perf` localStorage flag
 *  so the setting survives reloads. No-op when `localStorage` is unavailable
 *  (SSR / non-browser env). */
export function setEnabled(on: boolean): void {
  if (typeof localStorage !== 'undefined') {
    try {
      if (on) localStorage.setItem(STORAGE_KEY, '1')
      else localStorage.removeItem(STORAGE_KEY)
    } catch {
      // Non-persistent env — keep the in-memory flag only.
    }
  }
  enabled = on
  if (!on) buffers = new Map()
  notify()
}

/** Begin a timed region. Returns a function you call when the work is done;
 *  pass optional `count` + `meta` to enrich the recorded sample. The region
 *  is also wrapped in `performance.mark`/`performance.measure` so it appears
 *  in DevTools' Performance timeline. No-op when instrumentation is off.
 *
 *  @example
 *    const done = perf.begin('transcriptToMessages')
 *    const msgs = transcriptToMessages(entries)
 *    done({ count: entries.length }) */
export function begin(name: string): (extra?: { count?: number; meta?: Record<string, string | number | undefined> }) => void {
  if (!enabled) return () => {}
  const startMark = `${name}-start-${++seq}`
  const endMark = `${name}-end-${seq}`
  if (typeof performance !== 'undefined' && performance.mark) {
    performance.mark(startMark)
  }
  const t0 = now()
  return (extra) => {
    const t1 = now()
    if (typeof performance !== 'undefined' && performance.mark) {
      performance.mark(endMark)
      try {
        performance.measure(name, startMark, endMark)
      } catch {
        // Some browsers throw if marks are gone; we don't care.
      }
    }
    push(name, { durMs: round(t1 - t0), count: extra?.count, meta: extra?.meta, at: t1 })
  }
}

/** Record an explicit timing (e.g. parsed from a `Server-Timing` header) into
 *  the named operation's ring buffer. No-op when instrumentation is off. */
export function record(name: string, sample: Omit<PerfSample, 'at'> & { at?: number }): void {
  if (!enabled) return
  push(name, { durMs: sample.durMs, count: sample.count, meta: sample.meta, at: sample.at ?? now() })
}

/** Parse a `Server-Timing` header value into per-phase samples and record
 *  each under a frontend operation name. The header format (per the spec)
 *  is a comma-separated list of `name;dur=N;desc="..."` tokens. The backend
 *  emits:
 *    tt;dur=N;desc="total", fr;dur=N;desc="file-read", pr;dur=N;desc="parse",
 *    rc;dur=N;desc="reconstruct", rw;dur=N;desc="rewrite",
 *    src;desc="conv+entries", n;desc="127"
 *
 *  We map each numeric phase to a `server.<desc>` operation name, and the
 *  source + entry count into a single `server.transcript` sample with the
 *  source + count as meta. The `opLabel` argument namespaces the samples
 *  (e.g. `transcript.seed`) so a single fetch's phases are grouped together
 *  in the overlay.
 *
 *  No-op when instrumentation is off or the header is absent/empty. */
export function recordServerTiming(header: string | null | undefined, opLabel: string): void {
  if (!enabled || !header) return
  const phases = parseServerTiming(header)
  const source = phases.find((p) => p.name === 'src')?.desc
  const countTok = phases.find((p) => p.name === 'n')
  const count = countTok?.desc != null ? parseInt(countTok.desc, 10) : undefined
  for (const p of phases) {
    if (p.dur == null) continue // skip metadata-only tokens (src / n)
    record(`server.${opLabel}.${p.desc ?? p.name}`, {
      durMs: p.dur,
      meta: { source, count },
    })
  }
}

/** Convenience: parse the `Server-Timing` header from a `Response` and
 *  record each phase. Caller passes the `opLabel` (e.g. `transcript.seed`)
 *  so the overlay can group the phases. */
export async function recordFetch(opLabel: string, res: Response): Promise<Response> {
  if (!enabled) return res
  const st = res.headers.get('Server-Timing')
  recordServerTiming(st, opLabel)
  return res
}

/** Snapshot of every operation's ring buffer (most-recent-first). The
 *  overlay calls this on a 250ms interval. Returns an empty object when
 *  instrumentation is off. */
export function getSnapshot(): PerfSnapshot {
  const operations: Record<string, PerfSample[]> = {}
  for (const [name, buf] of buffers) {
    operations[name] = buf
  }
  return { operations, enabled }
}

/** Subscribe to snapshot updates (fires once on subscribe + on every
 *  change + on enable/disable toggle). Returns an unsubscribe function.
 *  Used by the overlay; tests can use it to assert instrumentation fired.
 *
 *  The listener is ALWAYS registered, even when instrumentation is off at
 *  subscribe time. This is critical for the overlay: it mounts in the
 *  disabled state (so it renders nothing), but it MUST still be notified
 *  when `setEnabled(true)` flips the flag on — otherwise the overlay would
 *  never appear. The initial fire carries `enabled: false` so the overlay
 *  renders null until the user toggles it on. */
export function subscribe(cb: (snap: PerfSnapshot) => void): () => void {
  listeners.add(cb)
  cb(getSnapshot())
  return () => { listeners.delete(cb) }
}

// ── internal ────────────────────────────────────────────────────────────

let seq = 0

function push(name: string, sample: PerfSample): void {
  let buf = buffers.get(name)
  if (!buf) { buf = []; buffers.set(name, buf) }
  buf.unshift(sample)
  if (buf.length > RING_CAPACITY) buf.length = RING_CAPACITY
  notify()
}

function notify(): void {
  if (listeners.size === 0) return
  const snap = getSnapshot()
  for (const cb of listeners) cb(snap)
}

function now(): number {
  return typeof performance !== 'undefined' && performance.now
    ? performance.now()
    : Date.now()
}

function round(ms: number): number {
  return Math.round(ms * 100) / 100
}

// ── Server-Timing parsing ────────────────────────────────────────────────

export interface ServerTimingPhase {
  /** Short token name (e.g. `tt`, `fr`, `src`). */
  name: string
  /** Duration in milliseconds, or undefined for tokens that carry only a
   *  `desc` (e.g. `src;desc="conv+entries"`). */
  dur?: number
  /** Description string (unquoted), or undefined when absent. */
  desc?: string
}

/** Parse a `Server-Timing` header value into its phase tokens. Tolerant of
 *  missing quotes, trailing params, and arbitrary whitespace per
 *  <https://www.w3.org/TR/server-timing/>. Pure function — exported for unit
 *  testing. */
export function parseServerTiming(header: string): ServerTimingPhase[] {
  const out: ServerTimingPhase[] = []
  // Split on commas NOT inside quotes.
  let depth = 0
  let cur = ''
  const parts: string[] = []
  for (let i = 0; i < header.length; i++) {
    const ch = header[i]!
    if (ch === '"') { depth = depth === 0 ? 1 : 0 }
    if (ch === ',' && depth === 0) { parts.push(cur); cur = '' }
    else cur += ch
  }
  if (cur.length > 0) parts.push(cur)
  for (const p of parts) {
    const trimmed = p.trim()
    if (!trimmed) continue
    const toks = trimmed.split(';').map((s) => s.trim())
    const name = toks[0]
    if (!name) continue
    let dur: number | undefined
    let desc: string | undefined
    for (let i = 1; i < toks.length; i++) {
      const t = toks[i]!
      if (t.startsWith('dur=')) {
        const v = t.slice(4)
        const n = parseFloat(v)
        if (!Number.isNaN(n)) dur = n
      } else if (t.startsWith('desc=')) {
        let v = t.slice(5)
        if (v.startsWith('"') && v.endsWith('"')) v = v.slice(1, -1)
        desc = v
      }
    }
    out.push({ name, dur, desc })
  }
  return out
}