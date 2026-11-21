import { useCallback, useEffect, useState } from 'react'
import { fetchAuthStatus, logout, type AuthStatus } from '../lib/auth'
import { notifyAuthChanged } from '../lib/unauthorized'

/**
 * "Sign out" — only meaningful when a passkey session actually exists.
 *
 * The session cookie is persistent (24 h idle, 7 day absolute), so on a shared
 * machine closing the tab is not a sign-out. This is the only way to end the
 * session from the UI without waiting for it to expire.
 *
 * Renders nothing in the `open` and `unconfigured` states: there is no session
 * to end there, and a dead control is worse than no control.
 *
 * Signing out **reloads the page**. The session cookie is dropped by the
 * server, but the already-open WebSocket was authorised at handshake time and
 * would keep delivering transcript frames to an unmounted UI; a reload is the
 * one thing that reliably closes it and clears every in-memory transcript.
 * The reload is injectable so a test can observe it without navigating.
 */
export function SignOutButton({
  className = '',
  reloadPage = () => window.location.reload(),
}: { className?: string; reloadPage?: () => void }) {
  const [status, setStatus] = useState<AuthStatus | null>(null)
  const [busy, setBusy] = useState(false)

  const load = useCallback(async () => {
    const res = await fetchAuthStatus()
    setStatus(res.ok ? res.data : null)
  }, [])

  useEffect(() => { void load() }, [load])

  // Re-read when the gate changes state, so the button appears after signing in
  // and disappears after signing out.
  useEffect(() => {
    const refresh = () => { void load() }
    window.addEventListener('seal-auth-changed', refresh)
    return () => window.removeEventListener('seal-auth-changed', refresh)
  }, [load])

  if (!status || status.state !== 'passkey' || !status.authenticated) return null

  const signOut = async () => {
    setBusy(true)
    await logout()
    setBusy(false)
    setStatus(null)
    notifyAuthChanged()
    reloadPage()
  }

  return (
    <button
      className={`signout-button ${className}`.trim()}
      onClick={() => { void signOut() }}
      disabled={busy}
      title="End this passkey session on this browser"
    >
      {busy ? 'Signing out…' : 'Sign out'}
    </button>
  )
}
