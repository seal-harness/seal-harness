import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'
import {
  rateLimitedLog,
  detectLoop,
  logMemoryNow,
  startMemoryMonitor,
  _resetDiagForTests,
} from '../diag'

/** Helper: mock performance.now with a controllable value. */
function mockPerfNow() {
  let t = 0
  const spy = vi.spyOn(performance, 'now')
  spy.mockReturnValue(0)
  const set = (val: number) => { t = val; spy.mockReturnValue(val) }
  const tick = (ms = 1) => { t += ms; spy.mockReturnValue(t) }
  return { set, tick, spy }
}

describe('diag', () => {
  beforeEach(() => {
    _resetDiagForTests()
    vi.spyOn(console, 'log').mockImplementation(() => {})
    vi.spyOn(console, 'warn').mockImplementation(() => {})
  })

  afterEach(() => {
    vi.restoreAllMocks()
  })

  describe('rateLimitedLog', () => {
    it('logs the first call immediately', () => {
      const logSpy = console.log as ReturnType<typeof vi.fn>
      rateLimitedLog('test-tag', 1000, () => 'hello')
      expect(logSpy).toHaveBeenCalledWith('[diag] test-tag: hello')
    })

    it('suppresses repeated calls within the interval', () => {
      const logSpy = console.log as ReturnType<typeof vi.fn>
      const perf = mockPerfNow()
      rateLimitedLog('test-tag', 1000, () => 'hello')
      perf.tick(100)
      rateLimitedLog('test-tag', 1000, (c) => `hello${c}`)
      perf.tick(100)
      rateLimitedLog('test-tag', 1000, (c) => `hello${c}`)
      // Only the first call should have logged
      expect(logSpy).toHaveBeenCalledTimes(1)
    })

    it('logs again after the interval elapses with suppressed count', () => {
      const perf = mockPerfNow()
      const logSpy = console.log as ReturnType<typeof vi.fn>
      rateLimitedLog('test-tag', 100, () => 'first')
      perf.tick(150)
      rateLimitedLog('test-tag', 100, (c) => `second+${c}`)
      expect(logSpy).toHaveBeenCalledTimes(2)
    })

    it('tracks independent tags separately', () => {
      const logSpy = console.log as ReturnType<typeof vi.fn>
      rateLimitedLog('tag-a', 1000, () => 'a')
      rateLimitedLog('tag-b', 1000, () => 'b')
      expect(logSpy).toHaveBeenCalledTimes(2)
      expect(logSpy).toHaveBeenCalledWith('[diag] tag-a: a')
      expect(logSpy).toHaveBeenCalledWith('[diag] tag-b: b')
    })
  })

  describe('detectLoop', () => {
    it('returns false when count is below threshold', () => {
      const perf = mockPerfNow()
      for (let i = 0; i < 5; i++) {
        perf.tick(1)
        expect(detectLoop('test-loop', 200, 10)).toBe(false)
      }
    })

    it('returns true and warns when count exceeds threshold', () => {
      const perf = mockPerfNow()
      const warnSpy = console.warn as ReturnType<typeof vi.fn>
      for (let i = 0; i < 9; i++) {
        perf.tick(1)
        detectLoop('test-loop', 200, 10)
      }
      // 10th call should trigger the warning
      perf.tick(1)
      const detected = detectLoop('test-loop', 200, 10)
      expect(detected).toBe(true)
      expect(warnSpy).toHaveBeenCalledWith(
        expect.stringContaining('LOOP DETECTED'),
      )
      expect(warnSpy).toHaveBeenCalledWith(
        expect.stringContaining('test-loop'),
      )
    })

    it('does not warn again within the same window', () => {
      const perf = mockPerfNow()
      const warnSpy = console.warn as ReturnType<typeof vi.fn>
      for (let i = 0; i < 15; i++) {
        perf.tick(1)
        detectLoop('test-loop', 200, 10)
      }
      expect(warnSpy).toHaveBeenCalledTimes(1)
    })

    it('resets after the window elapses', () => {
      const perf = mockPerfNow()
      const warnSpy = console.warn as ReturnType<typeof vi.fn>
      for (let i = 0; i < 15; i++) {
        perf.tick(1)
        detectLoop('test-loop', 100, 10)
      }
      expect(warnSpy).toHaveBeenCalledTimes(1)
      // Advance past the window — all old timestamps pruned
      perf.set(250)
      // Should not immediately warn again — timestamps were pruned
      for (let i = 0; i < 5; i++) {
        perf.tick(1)
        expect(detectLoop('test-loop', 100, 10)).toBe(false)
      }
    })

    it('tracks independent tags separately', () => {
      const perf = mockPerfNow()
      for (let i = 0; i < 15; i++) {
        perf.tick(1)
        detectLoop('tag-a', 200, 10)
      }
      // tag-b should not be affected by tag-a's rapid firing
      for (let i = 0; i < 5; i++) {
        perf.tick(1)
        expect(detectLoop('tag-b', 200, 10)).toBe(false)
      }
    })
  })

  describe('startMemoryMonitor', () => {
    it('logs unavailable when performance.memory is undefined', () => {
      const logSpy = console.log as ReturnType<typeof vi.fn>
      // performance.memory is not available in the test environment
      startMemoryMonitor()
      expect(logSpy).toHaveBeenCalledWith(
        expect.stringContaining('performance.memory unavailable'),
      )
    })

    it('is safe to call multiple times', () => {
      startMemoryMonitor()
      startMemoryMonitor()
      startMemoryMonitor()
      // Should not throw or create multiple intervals
    })
  })

  describe('logMemoryNow', () => {
    it('is a no-op when performance.memory is unavailable', () => {
      const logSpy = console.log as ReturnType<typeof vi.fn>
      logMemoryNow('test')
      expect(logSpy).not.toHaveBeenCalled()
    })
  })

  describe('_resetDiagForTests', () => {
    it('clears all state so tests start fresh', () => {
      // Populate some state
      rateLimitedLog('tag', 1000, () => 'x')
      detectLoop('tag', 200, 10)
      _resetDiagForTests()
      // After reset, the first call to rateLimitedLog should log immediately
      const logSpy = console.log as ReturnType<typeof vi.fn>
      logSpy.mockClear()
      rateLimitedLog('tag', 1000, () => 'fresh')
      expect(logSpy).toHaveBeenCalledTimes(1)
    })
  })
})
