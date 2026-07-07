import '@testing-library/jest-dom/vitest'

// jsdom does not implement scrollIntoView; ChatArea's sticky-bottom effect
// calls it on a ref. Stub it as a no-op so component tests can render.
if (typeof Element !== 'undefined' && !Element.prototype.scrollIntoView) {
  Element.prototype.scrollIntoView = function scrollIntoView() {}
}
