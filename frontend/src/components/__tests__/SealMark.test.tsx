import { render, screen } from '@testing-library/react'
import { describe, it, expect } from 'vitest'
import {
  SealMark,
  sealMarkVariant,
  SEAL_COLOURS,
} from '../SealMark'

/**
 * These tests pin the properties that make the mark usable in the UI, rather
 * than pinning pixel values (which the generator owns). Each one corresponds
 * to a measured requirement from the design work.
 */
describe('SealMark', () => {
  it('renders one closed silhouette path', () => {
    const { container } = render(<SealMark />)
    const paths = container.querySelectorAll('path')
    expect(paths.length).toBe(1)
    const path = paths.item(0)
    expect(path).not.toBeNull()
    const d = path.getAttribute('d') ?? ''
    // one moveto, and closed — the whole point is a single continuous outline
    expect((d.match(/M/g) ?? []).length).toBe(1)
    expect(d.trim().endsWith('Z')).toBe(true)
  })

  it('uses the brand colours sampled from the original artwork', () => {
    const { container } = render(<SealMark variant="large" />)
    const fills = [...container.querySelectorAll('path, circle')].map((el) =>
      el.getAttribute('fill'),
    )
    expect(fills).toContain(SEAL_COLOURS.body)
    expect(fills).toContain(SEAL_COLOURS.lineart)
    // the large drawing has a catchlight; that is the only place white appears
    expect(fills).toContain(SEAL_COLOURS.highlight)
  })

  it('has no background, ring or wordmark — only the mark', () => {
    const { container } = render(<SealMark />)
    const svg = container.querySelector('svg')!
    expect(svg.querySelectorAll('rect')).toHaveLength(0)
    expect(svg.querySelectorAll('text')).toHaveLength(0)
  })

  describe('drawing selection by size', () => {
    it('uses the small drawing below 24px', () => {
      expect(sealMarkVariant(16)).toBe('small')
      expect(sealMarkVariant(20)).toBe('small')
      expect(sealMarkVariant(23)).toBe('small')
    })

    it('uses the large drawing from 24px up', () => {
      expect(sealMarkVariant(24)).toBe('large')
      expect(sealMarkVariant(28)).toBe('large')
      expect(sealMarkVariant(96)).toBe('large')
    })

    it('draws a larger eye in the small drawing', () => {
      // The eye must be >= 2 device px at 16px. That is only achievable with
      // the enlarged eye, which is why two drawings exist at all.
      const small = render(<SealMark variant="small" />).container
      const large = render(<SealMark variant="large" />).container
      const r = (c: HTMLElement) => {
        const eye = c.querySelectorAll('circle').item(0)
        expect(eye).not.toBeNull()
        return Number(eye.getAttribute('r'))
      }
      expect(r(small)).toBeGreaterThan(r(large))
    })

    it('keeps the eye at least 2px wide at 16px', () => {
      // The 120-unit space maps to `size` px, so an eye of radius r renders
      // 2*r*size/120 px wide. At 16px with the small drawing that must be >=2.
      const size = 16
      const { container } = render(<SealMark size={size} />)
      const eye = container.querySelectorAll('circle').item(0)
      expect(eye).not.toBeNull()
      const r = Number(eye.getAttribute('r'))
      const eyePx = (2 * r * size) / 120
      expect(eyePx).toBeGreaterThanOrEqual(2)
    })
  })

  describe('accessibility', () => {
    it('is labelled by default', () => {
      render(<SealMark />)
      const img = screen.getByRole('img', { name: 'Seal Harness' })
      expect(img).toBeTruthy()
    })

    it('is hidden from assistive tech when title is null', () => {
      const { container } = render(<SealMark title={null} />)
      const svg = container.querySelector('svg')!
      expect(svg.getAttribute('aria-hidden')).toBe('true')
      expect(screen.queryByRole('img')).toBeNull()
    })

    it('does not leave a focusable element in the tab order when hidden', () => {
      const { container } = render(<SealMark title={null} />)
      const svg = container.querySelector('svg')!
      expect(svg.getAttribute('focusable')).toBe('false')
    })
  })

  it('scales by the size prop without changing the viewBox', () => {
    const a = render(<SealMark size={16} />).container.querySelector('svg')!
    const b = render(<SealMark size={96} />).container.querySelector('svg')!
    expect(a.getAttribute('viewBox')).toBe(b.getAttribute('viewBox'))
    expect(a.getAttribute('width')).toBe('16')
    expect(b.getAttribute('width')).toBe('96')
  })
})
