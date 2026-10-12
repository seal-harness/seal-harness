/**
 * Diagnostic logging for investigating Chrome renderer crashes (Error
 * code: 5 / STATUS_ACCESS_VIOLATION).
 *
 * Always-on (not gated by a flag) — the purpose is to catch an intermittent
 * crash, so the logging must be active by default. All logs use a `[diag]`
 * prefix so they're easy to filter in DevTools.
 *
 * Three mechanisms:
 *
 *   1. **Memory monitor** — samples `performance.memory` (Chrome-only) every
 *      5s and logs a warning when the JS heap grows by > 50MB between
 *      samples. After a renderer crash, the DevTools console buffer shows
 *      the heap trajectory leading up to the crash.
 *
 *   2. **Rate-limited logging** — `rateLimitedLog` logs at most once per
 *      `intervalMs` per tag, collapsing repeated calls into a single line
 *      with a count. This prevents a feedback loop from filling the console
 *      buffer and pushing out earlier diagnostic messages.
 *
 *   3. **Loop detector** — `detectLoop` counts how many times a tag fires
 *      within a rolling 200ms window and logs a warning when the count
 *      exceeds a threshold. This catches rapid-fire render/measure/scroll
 *      cycles that could crash the renderer before the console can even
 *      flush.
 *
 * @module
 */

// ── Types ────────────────────────────────────────────────────────────────

interface MemorySample {
  usedJSHeapSize: number
  totalJSHeapSize: number
  jsHeapSizeLimit: number
  at: number
}

// ── Rate-limited logging ─────────────────────────────────────────────────

interface RateLimitState {
  lastLogAt: number
  countSinceLastLog: number
}

const rateLimitMap = new Map<string, RateLimitState>()

/** Log at most once per `intervalMs` per `tag`. Repeated calls within the
 *  window are counted and the count is included in the next log line. This
 *  prevents a tight loop from flooding the console while still showing that
 *  the loop is happening.
 *
 *  Always logs the first call for a given tag (so the initial state is
 *  visible), then rate-limits subsequent calls. */
export function rateLimitedLog(
  tag: string,
  intervalMs: number,
  fn: (collapsedCount: number) => string,
): void {
  const now = performance.now()
  const state = rateLimitMap.get(tag)
  if (state === undefined) {
    // First call for this tag — log immediately.
    console.log(`[diag] ${tag}: ${fn(0)}`)
    rateLimitMap.set(tag, { lastLogAt: now, countSinceLastLog: 0 })
    return
  }
  state.countSinceLastLog++
  if (now - state.lastLogAt >= intervalMs) {
    const collapsed = state.countSinceLastLog
    console.log(`[diag] ${tag}: ${fn(collapsed)}${collapsed > 0 ? ` (+${collapsed} suppressed)` : ''}`)
    state.lastLogAt = now
    state.countSinceLastLog = 0
  }
}

// ── Loop detector ────────────────────────────────────────────────────────

interface LoopDetectorState {
  timestamps: number[]
  warnedAt: number
}

const loopDetectorMap = new Map<string, LoopDetectorState>()

/** Track how many times `tag` fires within a rolling `windowMs` window. When
 *  the count exceeds `threshold`, log a warning (rate-limited to once per
 *  `windowMs` so the warning itself doesn't loop).
 *
 *  @example
 *    detectLoop('VW.measure', 200, 15) // warn if 15+ measures in 200ms */
export function detectLoop(tag: string, windowMs: number, threshold: number): boolean {
  const now = performance.now()
  let state = loopDetectorMap.get(tag)
  if (state === undefined) {
    state = { timestamps: [], warnedAt: -Infinity }
    loopDetectorMap.set(tag, state)
  }
  // Prune timestamps outside the window.
  const cutoff = now - windowMs
  while (state.timestamps.length > 0 && state.timestamps[0]! < cutoff) {
    state.timestamps.shift()
  }
  state.timestamps.push(now)
  if (state.timestamps.length >= threshold && now - state.warnedAt >= windowMs) {
    state.warnedAt = now
    console.warn(`[diag] LOOP DETECTED: "${tag}" fired ${state.timestamps.length} times in ${windowMs}ms (threshold=${threshold})`)
    return true
  }
  return false
}

// ── Memory monitor ───────────────────────────────────────────────────────

let memoryInterval: ReturnType<typeof setInterval> | null = null
let lastMemorySample: MemorySample | null = null
const MEMORY_INTERVAL_MS = 5000
const MEMORY_GROWTH_WARN_MB = 50

/** Read `performance.memory` (Chrome-only). Returns null when unavailable. */
function readMemory(): MemorySample | null {
  const perf = performance as Performance & {
    memory?: { usedJSHeapSize: number; totalJSHeapSize: number; jsHeapSizeLimit: number }
  }
  if (typeof perf.memory === 'undefined') return null
  const m = perf.memory
  return {
    usedJSHeapSize: m.usedJSHeapSize,
    totalJSHeapSize: m.totalJSHeapSize,
    jsHeapSizeLimit: m.jsHeapSizeLimit,
    at: Date.now(),
  }
}

function formatMB(bytes: number): string {
  return `${(bytes / 1024 / 1024).toFixed(1)}MB`
}

/** Log a single memory sample. Called by the interval and by `logMemoryNow`. */
function logMemory(sample: MemorySample): void {
  const parts = [
    `heap=${formatMB(sample.usedJSHeapSize)}`,
    `total=${formatMB(sample.totalJSHeapSize)}`,
    `limit=${formatMB(sample.jsHeapSizeLimit)}`,
  ]
  if (lastMemorySample !== null) {
    const delta = sample.usedJSHeapSize - lastMemorySample.usedJSHeapSize
    const deltaMB = delta / 1024 / 1024
    if (Math.abs(deltaMB) >= 1) {
      parts.push(`delta=${deltaMB > 0 ? '+' : ''}${deltaMB.toFixed(1)}MB`)
    }
    if (deltaMB > MEMORY_GROWTH_WARN_MB) {
      console.warn(`[diag] MEMORY: heap grew by ${deltaMB.toFixed(1)}MB in ${MEMORY_INTERVAL_MS}ms — possible leak`)
    }
  }
  console.log(`[diag] MEMORY ${parts.join(' ')}`)
  lastMemorySample = sample
}

/** Start the periodic memory monitor. Safe to call multiple times — the
 *  previous interval is cleared before starting a new one. No-op when
 *  `performance.memory` is unavailable (non-Chrome browsers). */
export function startMemoryMonitor(): void {
  if (memoryInterval !== null) return
  const initial = readMemory()
  if (initial === null) {
    console.log('[diag] MEMORY monitor: performance.memory unavailable (non-Chrome?)')
    return
  }
  console.log(`[diag] MEMORY monitor started — heap=${formatMB(initial.usedJSHeapSize)} limit=${formatMB(initial.jsHeapSizeLimit)}`)
  lastMemorySample = initial
  memoryInterval = setInterval(() => {
    const sample = readMemory()
    if (sample !== null) logMemory(sample)
  }, MEMORY_INTERVAL_MS)
}

/** Log the current memory state immediately (outside the interval). Useful
 *  for logging memory at specific application events (e.g. session switch,
 *  transcript load). No-op when `performance.memory` is unavailable. */
export function logMemoryNow(tag: string): void {
  const sample = readMemory()
  if (sample === null) return
  console.log(`[diag] MEMORY [${tag}] heap=${formatMB(sample.usedJSHeapSize)} total=${formatMB(sample.totalJSHeapSize)}`)
}

// ── Reset (test-only) ────────────────────────────────────────────────────

/** Reset all internal state. Test-only — clears rate-limit counters, loop
 *  detector timestamps, and the memory monitor interval. */
export function _resetDiagForTests(): void {
  rateLimitMap.clear()
  loopDetectorMap.clear()
  if (memoryInterval !== null) {
    clearInterval(memoryInterval)
    memoryInterval = null
  }
  lastMemorySample = null
}
