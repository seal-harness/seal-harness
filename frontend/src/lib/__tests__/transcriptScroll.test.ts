import { describe, it, expect } from 'vitest'
import {
  AT_BOTTOM_PX,
  AT_TOP_PX,
  isAtBottom,
  isNearTop,
  computeVisibleRange,
  computeSpacers,
  blendRowHeight,
  spacerScrollAdjustment,
  isSyntheticScroll,
} from '../transcriptScroll'

const metrics = (scrollTop: number, scrollHeight: number, clientHeight: number) => ({
  scrollTop,
  scrollHeight,
  clientHeight,
})

describe('transcriptScroll', () => {
  describe('isAtBottom', () => {
    it('is true within the threshold of the bottom', () => {
      expect(isAtBottom(metrics(9400, 10000, 600))).toBe(true) // distance 0
      expect(isAtBottom(metrics(9321, 10000, 600))).toBe(true) // distance 79
    })

    it('is false beyond the threshold', () => {
      expect(isAtBottom(metrics(9320, 10000, 600))).toBe(false) // distance 80
      expect(isAtBottom(metrics(0, 10000, 600))).toBe(false)
    })

    it('treats an empty scroller as at the bottom', () => {
      expect(isAtBottom(metrics(0, 0, 0))).toBe(true)
    })

    it('honours a custom threshold', () => {
      expect(isAtBottom(metrics(9975, 10000, 0), 50)).toBe(true)
      expect(isAtBottom(metrics(9900, 10000, 0), 50)).toBe(false)
    })

    it('returns false for non-finite metrics', () => {
      expect(isAtBottom(metrics(Number.NaN, 10000, 600))).toBe(false)
      expect(isAtBottom(metrics(0, Number.POSITIVE_INFINITY, 600))).toBe(false)
    })

    it('exposes the 80px default', () => {
      expect(AT_BOTTOM_PX).toBe(80)
    })
  })

  describe('isNearTop', () => {
    it('uses a 60px default and a strict comparison', () => {
      expect(AT_TOP_PX).toBe(60)
      expect(isNearTop(metrics(0, 1000, 600))).toBe(true)
      expect(isNearTop(metrics(59, 1000, 600))).toBe(true)
      expect(isNearTop(metrics(60, 1000, 600))).toBe(false)
    })

    it('returns false for non-finite scrollTop', () => {
      expect(isNearTop(metrics(Number.NaN, 1000, 600))).toBe(false)
    })
  })

  describe('computeVisibleRange', () => {
    const base = {
      scrollTop: 12000,
      viewportHeight: 600,
      avgRowHeight: 120,
      messageCount: 1000,
      overscan: 50,
      minRendered: 100,
    }

    it('starts at 0 when scrolled to the top', () => {
      expect(computeVisibleRange({ ...base, scrollTop: 0 }).startIndex).toBe(0)
    })

    it('ends at messageCount at the bottom', () => {
      expect(computeVisibleRange({ ...base, scrollTop: 114000 }).endIndex).toBe(1000)
    })

    it('renders at least minRendered entries', () => {
      const { startIndex, endIndex } = computeVisibleRange({ ...base, scrollTop: 60000 })
      expect(endIndex - startIndex).toBeGreaterThanOrEqual(100)
    })

    it('never returns a range outside [0, messageCount]', () => {
      for (const scrollTop of [-500, 0, 1, 50000, 10 ** 9]) {
        const { startIndex, endIndex } = computeVisibleRange({ ...base, scrollTop })
        expect(startIndex).toBeGreaterThanOrEqual(0)
        expect(endIndex).toBeLessThanOrEqual(1000)
        expect(startIndex).toBeLessThanOrEqual(endIndex)
      }
    })

    it('handles zero messages and degenerate inputs', () => {
      expect(computeVisibleRange({ ...base, messageCount: 0 })).toEqual({ startIndex: 0, endIndex: 0 })
      expect(computeVisibleRange({ ...base, avgRowHeight: 0 }).startIndex).toBeGreaterThanOrEqual(0)
      expect(computeVisibleRange({ ...base, avgRowHeight: Number.NaN }).startIndex).toBeGreaterThanOrEqual(0)
      expect(computeVisibleRange({ ...base, scrollTop: Number.NaN }).startIndex).toBe(0)
    })
  })

  describe('computeSpacers', () => {
    it('is zero for a full range', () => {
      expect(computeSpacers({ startIndex: 0, endIndex: 10 }, 10, 120)).toEqual({ top: 0, bottom: 0 })
    })

    it('estimates unrendered regions from the average row height', () => {
      expect(computeSpacers({ startIndex: 10, endIndex: 20 }, 30, 100)).toEqual({
        top: 1000,
        bottom: 1000,
      })
    })

    it('never returns a negative height', () => {
      // startIndex is clamped to messageCount (20), so the top spacer is
      // 20 rows, not 50.
      expect(computeSpacers({ startIndex: 50, endIndex: 10 }, 20, 100)).toEqual({ top: 2000, bottom: 0 })
      expect(computeSpacers({ startIndex: 0, endIndex: 500 }, 20, 100)).toEqual({ top: 0, bottom: 0 })
    })

    it('handles a non-finite average', () => {
      expect(computeSpacers({ startIndex: 5, endIndex: 10 }, 20, Number.NaN)).toEqual({ top: 0, bottom: 0 })
    })
  })

  describe('blendRowHeight', () => {
    it('blends 85/15 toward the measurement', () => {
      expect(blendRowHeight(100, 200, 2)).toBe(100) // 100*0.85 + 100*0.15
      expect(blendRowHeight(100, 200, 1)).toBe(115)
    })

    it('returns the previous value for degenerate measurements', () => {
      expect(blendRowHeight(100, 0, 5)).toBe(100)
      expect(blendRowHeight(100, 500, 0)).toBe(100)
      expect(blendRowHeight(100, Number.NaN, 5)).toBe(100)
      expect(blendRowHeight(100, -50, 5)).toBe(100)
    })

    it('never returns a non-positive average', () => {
      expect(blendRowHeight(1, 1, 100)).toBeGreaterThan(0)
    })
  })

  describe('spacerScrollAdjustment', () => {
    it('is the spacer-height delta for the rows above the viewport', () => {
      expect(spacerScrollAdjustment(10, 100, 110)).toBe(100)
      expect(spacerScrollAdjustment(10, 110, 100)).toBe(-100)
      expect(spacerScrollAdjustment(0, 100, 200)).toBe(0)
    })

    it('is 0 for non-finite input', () => {
      expect(spacerScrollAdjustment(10, Number.NaN, 110)).toBe(0)
    })
  })

  describe('isSyntheticScroll', () => {
    it('matches the expected position within one pixel', () => {
      expect(isSyntheticScroll(100, 100)).toBe(true)
      expect(isSyntheticScroll(100.4, 100)).toBe(true)
      expect(isSyntheticScroll(101, 100)).toBe(true)
      expect(isSyntheticScroll(102, 100)).toBe(false)
      expect(isSyntheticScroll(0, 100)).toBe(false)
    })

    it('never matches when there is no expectation', () => {
      expect(isSyntheticScroll(100, null)).toBe(false)
    })
  })
})
