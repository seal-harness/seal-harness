import { describe, it, expect } from 'vitest'
import { nextScrollIntent, type ScrollIntent } from '../scrollIntent'

describe('scrollIntent reducer', () => {
  it('select-session follows the bottom unless a deep-link anchor is pinned', () => {
    expect(nextScrollIntent('top', { type: 'select-session', preserveAnchor: false })).toEqual({
      intent: 'bottom',
      fetch: null,
      scrollTo: null,
    })
    expect(nextScrollIntent('top', { type: 'select-session', preserveAnchor: true })).toEqual({
      intent: null,
      fetch: null,
      scrollTo: null,
    })
  })

  it('scroll-to-top fetches the beginning when the window is not at the start', () => {
    expect(nextScrollIntent(null, { type: 'scroll-to-top', atStart: false })).toEqual({
      intent: 'top',
      fetch: 'beginning',
      scrollTo: null,
    })
  })

  it('scroll-to-top scrolls immediately when already at the start', () => {
    expect(nextScrollIntent(null, { type: 'scroll-to-top', atStart: true })).toEqual({
      intent: null,
      fetch: null,
      scrollTo: 'top',
    })
  })

  it('repeated scroll-to-top is idempotent', () => {
    let intent: ScrollIntent = null
    for (let i = 0; i < 3; i++) {
      const step = nextScrollIntent(intent, { type: 'scroll-to-top', atStart: false })
      intent = step.intent
      expect(step).toEqual({ intent: 'top', fetch: 'beginning', scrollTo: null })
    }
  })

  it('scroll-to-bottom fetches the latest when the window is not at the end', () => {
    expect(nextScrollIntent(null, { type: 'scroll-to-bottom', atEnd: false })).toEqual({
      intent: 'bottom',
      fetch: 'latest',
      scrollTo: null,
    })
    expect(nextScrollIntent(null, { type: 'scroll-to-bottom', atEnd: true })).toEqual({
      intent: null,
      fetch: null,
      scrollTo: 'bottom',
    })
  })

  it('a top intent is consumed when content arrives', () => {
    expect(
      nextScrollIntent('top', { type: 'content-arrived', loading: false, empty: false, atBottom: false }),
    ).toEqual({ intent: null, fetch: null, scrollTo: 'top' })
  })

  it('a bottom intent is consumed when content arrives', () => {
    expect(
      nextScrollIntent('bottom', { type: 'content-arrived', loading: false, empty: false, atBottom: false }),
    ).toEqual({ intent: null, fetch: null, scrollTo: 'bottom' })
  })

  it('keeps the intent while content is still loading', () => {
    expect(
      nextScrollIntent('top', { type: 'content-arrived', loading: true, empty: false, atBottom: true }),
    ).toEqual({ intent: 'top', fetch: null, scrollTo: null })
  })

  it('clears the intent when the arriving content is empty', () => {
    expect(
      nextScrollIntent('top', { type: 'content-arrived', loading: false, empty: true, atBottom: true }),
    ).toEqual({ intent: null, fetch: null, scrollTo: null })
  })

  it('sticks to the bottom for new content when already at the bottom', () => {
    expect(
      nextScrollIntent(null, { type: 'content-arrived', loading: false, empty: false, atBottom: true }),
    ).toEqual({ intent: null, fetch: null, scrollTo: 'bottom' })
  })

  it('does not scroll for new content when the user is not at the bottom', () => {
    expect(
      nextScrollIntent(null, { type: 'content-arrived', loading: false, empty: false, atBottom: false }),
    ).toEqual({ intent: null, fetch: null, scrollTo: null })
  })

  it('near the top with older entries available requests older entries', () => {
    expect(
      nextScrollIntent(null, {
        type: 'scrolled',
        atTop: true,
        atBottom: false,
        hasNewer: true,
        canAutoLoadOlder: true,
      }),
    ).toEqual({ intent: null, fetch: 'older', scrollTo: null })
  })

  it('at the bottom while not viewing the latest follows with a latest fetch', () => {
    expect(
      nextScrollIntent(null, {
        type: 'scrolled',
        atTop: false,
        atBottom: true,
        hasNewer: true,
        canAutoLoadOlder: false,
      }),
    ).toEqual({ intent: 'bottom', fetch: 'latest', scrollTo: null })
  })

  it('a plain scroll observation changes nothing', () => {
    expect(
      nextScrollIntent('top', {
        type: 'scrolled',
        atTop: false,
        atBottom: false,
        hasNewer: false,
        canAutoLoadOlder: false,
      }),
    ).toEqual({ intent: 'top', fetch: null, scrollTo: null })
  })

  it('user-scrolled cancels any pending intent', () => {
    expect(nextScrollIntent('top', { type: 'user-scrolled' })).toEqual({
      intent: null,
      fetch: null,
      scrollTo: null,
    })
  })
})
