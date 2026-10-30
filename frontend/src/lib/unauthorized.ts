/**
 * One place that notices an expired session.
 *
 * Rather than sprinkling `if (res.status === 401)` through the ~45 call sites
 * in `useApi.ts`, the app installs a single `fetch` wrapper at startup. Any
 * 401 from the gateway dispatches `seal-unauthorized`, which `AccessGate`
 * listens for; the gate then re-fetches `/api/auth/status` and re-applies its
 * render table (it must not assume "login" — after a `reset --yes` and a
 * restart the state is `unconfigured`).
 *
 * The WebSocket path is covered indirectly: when the stream drops, the lists
 * hook falls back to REST polling, whose 401 raises this same event.
 */

export const UNAUTHORIZED_EVENT = 'seal-unauthorized'

let installed = false

export function installUnauthorizedInterceptor(): void {
  if (installed || typeof window === 'undefined' || typeof window.fetch !== 'function') return
  installed = true
  const original = window.fetch.bind(window)
  window.fetch = async (input: RequestInfo | URL, init?: RequestInit) => {
    const res = await original(input, init)
    if (res.status === 401) {
      window.dispatchEvent(new Event(UNAUTHORIZED_EVENT))
    }
    return res
  }
}
