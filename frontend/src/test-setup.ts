import '@testing-library/jest-dom/vitest'

// jsdom does not implement scrollIntoView; ChatArea's sticky-bottom effect
// calls it on a ref. Stub it as a no-op so component tests can render.
if (typeof Element !== 'undefined' && !Element.prototype.scrollIntoView) {
  Element.prototype.scrollIntoView = function scrollIntoView() {}
}


// Override WebSocket with a no-op stub so hooks that use streamClient()
// (e.g. useAgents) don't attempt real WS connections during tests.
globalThis.WebSocket = class WebSocket {
  static CONNECTING = 0
  static OPEN = 1
  static CLOSING = 2
  static CLOSED = 3
  readyState = 3 // CLOSED — prevents send attempts
  onopen: ((ev: Event) => void) | null = null
  onmessage: ((ev: MessageEvent) => void) | null = null
  onclose: ((ev: CloseEvent) => void) | null = null
  onerror: ((ev: Event) => void) | null = null
  constructor(_url: string | URL) {}
  send(_data: string | ArrayBufferLike | Blob | ArrayBufferView): void {}
  close(_code?: number, _reason?: string): void {}
  addEventListener(_type: string, _listener: EventListenerOrEventListenerObject): void {}
  removeEventListener(_type: string, _listener: EventListenerOrEventListenerObject): void {}
  dispatchEvent(_event: Event): boolean { return true }
} as unknown as typeof WebSocket
