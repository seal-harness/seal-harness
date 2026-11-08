/**
 * The client half of the setup endpoints.
 *
 * Every call returns `{ status, ok, error, hint, body }` rather than throwing:
 * the wizard branches on the status (400 = fix the field, 409 = someone else
 * already did it, 422 = this machine cannot, 413/415 = a bug) and renders the
 * server's fixed reason plus its actionable hint. The hint never carries key
 * material — that is the server's guarantee, not this module's.
 */
import { useCallback, useEffect, useState } from 'react'
import { parseSetupState, type ParsedSetupState } from '../lib/setupSteps'

export interface SetupResult {
  status: number
  ok: boolean
  error: string | null
  hint: string | null
  body: unknown
}

async function readJson(res: Response): Promise<unknown> {
  try {
    return await res.json()
  } catch {
    return null
  }
}

function toResult(status: number, body: unknown): SetupResult {
  const record = (typeof body === 'object' && body !== null ? body : {}) as Record<string, unknown>
  return {
    status,
    ok: status >= 200 && status < 300,
    error: typeof record.error === 'string' ? record.error : null,
    hint: typeof record.hint === 'string' ? record.hint : null,
    body,
  }
}

async function call(path: string, init?: RequestInit): Promise<SetupResult> {
  const res = await fetch(path, init)
  return toResult(res.status, await readJson(res))
}

function postJson(path: string, payload: unknown): Promise<SetupResult> {
  return call(path, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(payload),
  })
}

export type VaultBackend =
  | { backend: 'local' }
  | { backend: 'resume' }
  | { backend: 'yubikey'; touch: boolean; pin: boolean }
  | { backend: 'user'; recipient: string; identity_path: string }

export function provisionVault(spec: VaultBackend): Promise<SetupResult> {
  return postJson('/api/setup/vault', spec)
}

export function reopenVault(): Promise<SetupResult> {
  return postJson('/api/setup/vault/reopen', {})
}

export function setDefaultProvider(name: string): Promise<SetupResult> {
  return call('/api/providers/default', {
    method: 'PUT',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ provider: name }),
  })
}

export function testProvider(name: string, model?: string): Promise<SetupResult> {
  return postJson(`/api/providers/${encodeURIComponent(name)}/test`,
    model === undefined ? {} : { model })
}

export interface SetupStateResult {
  state: ParsedSetupState | null
  status: number
  error: string | null
  hint: string | null
  reload: () => void
}

/**
 * `GET /api/setup`, parsed. A malformed body is a failure (the gate fails
 * closed); a 403 is reported as such so the gate can explain that setup has to
 * run on the host.
 */
export function useSetupState(): SetupStateResult {
  const [state, setState] = useState<ParsedSetupState | null>(null)
  const [status, setStatus] = useState(0)
  const [error, setError] = useState<string | null>(null)
  const [hint, setHint] = useState<string | null>(null)
  const [nonce, setNonce] = useState(0)

  useEffect(() => {
    let cancelled = false
    const load = async (): Promise<void> => {
      const result = await call('/api/setup')
      if (cancelled) return
      setStatus(result.status)
      setError(result.error)
      setHint(result.hint)
      if (result.ok) {
        const parsed = parseSetupState(result.body)
        setState(parsed)
        if (parsed === null) {
          setError('the gateway returned a setup payload this build cannot read')
        }
      } else {
        setState(null)
      }
    }
    void load()
    return () => {
      cancelled = true
    }
  }, [nonce])

  const reload = useCallback(() => setNonce((n) => n + 1), [])
  return { state, status, error, hint, reload }
}
