/**
 * One place that notices the session changed.
 *
 * Rather than sprinkling `if (res.status === 401)` through the ~45 call sites
 * in `useApi.ts`, the app installs a single `fetch` wrapper at startup. Any
 * 401 from the gateway — and an explicit sign-out — dispatches
 * `seal-auth-changed`, which `AccessGate` listens for; the gate then re-fetches
 * `/api/auth/status` and re-applies its render table (it must not assume
 * "login": after a `reset --yes` and a restart the state is `unconfigured`).
 *
 * The WebSocket path is covered indirectly: a rejected handshake surfaces to
 * JavaScript only as close code 1006, and when the stream drops the lists hook
 * falls back to REST polling, whose 401 raises this same event.
 */

export const AUTH_CHANGED_EVENT = 'seal-auth-changed'

let installed = false

/** Tell the gate that the session state changed (sign-out, expiry, sign-in). */
export function notifyAuthChanged(): void {
  if (typeof window === 'undefined') return
  window.dispatchEvent(new Event(AUTH_CHANGED_EVENT))
}

export function installUnauthorizedInterceptor(): void {
  if (installed || typeof window === 'undefined' || typeof window.fetch !== 'function') return
  installed = true
  const original = window.fetch.bind(window)
  window.fetch = async (input: RequestInfo | URL, init?: RequestInit) => {
    const res = await original(input, init)
    if (res.status === 401) notifyAuthChanged()
    return res
  }
}
