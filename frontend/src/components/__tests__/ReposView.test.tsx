import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { render, screen, fireEvent, cleanup, waitFor } from '@testing-library/react'
import { ReposView } from '../ReposView'
import type { RepoInfo } from '../../types'
import type { RepoMutationResult } from '../../hooks/useApi'

// ── Mocks ────────────────────────────────────────────────────────────────

const createRepo = vi.fn(async (_input: unknown): Promise<RepoMutationResult> => ({ ok: false, error: 'network error' }))
const updateRepo = vi.fn(async (_id: string, _input: unknown): Promise<RepoInfo | null> => null)
const deleteRepo = vi.fn(async (_id: string): Promise<boolean> => false)

let reposState: RepoInfo[] = []
let reposError = false
let reposLoaded = true

// Vault secret KEY NAMES offered by the PAT-source dropdown. The real
// GET /api/secrets endpoint never returns values — only key names.
let secretsState: string[] = []
let secretsError = false
let secretsLoaded = true

vi.mock('../../hooks/useApi', () => ({
  createRepo: (input: unknown) => createRepo(input),
  updateRepo: (id: string, input: unknown) => updateRepo(id, input),
  deleteRepo: (id: string) => deleteRepo(id),
  useRepos: () => ({
    repos: reposState,
    loaded: reposLoaded,
    error: reposError,
    refresh: vi.fn(),
  }),
  useSecrets: () => ({
    secrets: secretsState,
    loaded: secretsLoaded,
    error: secretsError,
    refresh: vi.fn(),
  }),
}))

// ── Helpers ──────────────────────────────────────────────────────────────

function makeRepo(overrides: Partial<RepoInfo> = {}): RepoInfo {
  return {
    id: 'myrepo',
    url: 'git@github.com:owner/repo.git',
    vcs_kind: 'github',
    credential: { kind: 'pat', vault_key: 'GITHUB_PAT_MYREPO' },
    ...overrides,
  }
}

beforeEach(() => {
  reposState = []
  reposError = false
  reposLoaded = true
  secretsState = []
  secretsError = false
  secretsLoaded = true
  createRepo.mockReset()
  updateRepo.mockReset()
  deleteRepo.mockReset()
  createRepo.mockResolvedValue({ ok: false, error: 'network error' })
  updateRepo.mockResolvedValue(null)
  deleteRepo.mockResolvedValue(false)
})

afterEach(() => {
  cleanup()
})

// ── Tests ────────────────────────────────────────────────────────────────

describe('ReposView', () => {
  it('renders an empty state when no repos exist', () => {
    reposState = []
    render(<ReposView />)
    expect(screen.getByText(/No repos registered/i)).toBeTruthy()
  })

  it('renders a row per repo with a human-readable credential-kind badge', () => {
    reposState = [
      makeRepo({ id: 'myrepo', url: 'git@github.com:owner/repo.git', credential: { kind: 'pat', vault_key: 'GITHUB_PAT' } }),
      makeRepo({ id: 'other', url: 'git@github.com:owner/other.git', credential: { kind: 'deploy_key', vault_key: 'GH_DEPLOY' } }),
    ]
    render(<ReposView />)
    expect(screen.getByTestId('repo-row-myrepo')).toBeTruthy()
    expect(screen.getByTestId('repo-row-other')).toBeTruthy()
    // Human-readable credential-kind label (NOT the raw enum).
    expect(screen.getByText('Personal Access Token')).toBeTruthy()
    expect(screen.getByText('SSH Deploy Key')).toBeTruthy()
  })

  it('shows the load error banner when error=true', () => {
    reposError = true
    render(<ReposView />)
    expect(screen.getByTestId('repos-load-error')).toBeTruthy()
  })

  it('clicking New opens the create form', () => {
    reposState = []
    render(<ReposView />)
    fireEvent.click(screen.getByLabelText('New repo'))
    expect(screen.getByTestId('repo-form-new')).toBeTruthy()
    expect(screen.getByLabelText('Create repo')).toBeTruthy()
  })

  it('create POSTs /api/repos on a valid form', async () => {
    createRepo.mockResolvedValue({ ok: true, repo: makeRepo({ id: 'myrepo' }) })
    reposState = []
    render(<ReposView />)
    fireEvent.click(screen.getByLabelText('New repo'))
    fireEvent.change(document.getElementById('repo-id') as HTMLInputElement, { target: { value: 'myrepo' } })
    fireEvent.change(document.getElementById('repo-url') as HTMLInputElement, { target: { value: 'git@github.com:owner/repo.git' } })
    // vcs_kind defaults to github; leave as-is.
    // credential kind defaults to pat; vault_key is auto-generated.
    // pat requires a token — enter one.
    fireEvent.change(document.getElementById('repo-token') as HTMLInputElement, { target: { value: 'xyz' } })
    fireEvent.click(screen.getByLabelText('Create repo'))
    await waitFor(() => expect(createRepo).toHaveBeenCalledTimes(1))
    const body = createRepo.mock.calls[0]![0] as { id?: string; url: string; vcs_kind: string; token?: string; credential: { kind: string; vault_key: string } }
    expect(body.id).toBe('myrepo')
    expect(body.url).toBe('git@github.com:owner/repo.git')
    expect(body.vcs_kind).toBe('github')
    expect(body.credential.kind).toBe('pat')
    // vault_key is auto-generated: seal-<kind>-<id>
    expect(body.credential.vault_key).toBe('seal-pat-myrepo')
    expect(body.token).toBe('xyz')
  })

  it('create surfaces the backend error when the save fails', async () => {
    createRepo.mockResolvedValue({ ok: false, error: 'disallowed host: evil.example' })
    reposState = []
    render(<ReposView />)
    fireEvent.click(screen.getByLabelText('New repo'))
    fireEvent.change(document.getElementById('repo-id') as HTMLInputElement, { target: { value: 'myrepo' } })
    fireEvent.change(document.getElementById('repo-url') as HTMLInputElement, { target: { value: 'git@evil.example/o.git' } })
    fireEvent.change(document.getElementById('repo-token') as HTMLInputElement, { target: { value: 'xyz' } })
    fireEvent.click(screen.getByLabelText('Create repo'))
    await waitFor(() => expect(createRepo).toHaveBeenCalledTimes(1))
    expect(screen.getByTestId('repo-form-error')).toBeTruthy()
    expect(screen.getByText(/disallowed host: evil\.example/)).toBeTruthy()
  })

  it('create validates the id charset and surfaces an error for a bad id', () => {
    reposState = []
    render(<ReposView />)
    fireEvent.click(screen.getByLabelText('New repo'))
    fireEvent.change(document.getElementById('repo-id') as HTMLInputElement, { target: { value: 'bad/id' } })
    fireEvent.click(screen.getByLabelText('Create repo'))
    expect(screen.getByTestId('repo-form-error')).toBeTruthy()
    expect(createRepo).not.toHaveBeenCalled()
  })

  it('edit flow: clicking a row seeds the form; Save PUTs /api/repos/:id (id disabled)', async () => {
    updateRepo.mockResolvedValue(makeRepo({ id: 'myrepo', url: 'git@github.com:owner/repo2.git' }))
    reposState = [makeRepo({ id: 'myrepo', url: 'git@github.com:owner/repo.git', credential: { kind: 'pat', vault_key: 'GITHUB_PAT' } })]
    render(<ReposView />)
    fireEvent.click(screen.getByTestId('repo-row-myrepo'))
    expect(screen.getByTestId('repo-form-myrepo')).toBeTruthy()
    const idEl = document.getElementById('repo-id') as HTMLInputElement
    // id is stable → disabled when editing.
    expect(idEl.disabled).toBe(true)
    expect(idEl.value).toBe('myrepo')
    fireEvent.change(document.getElementById('repo-url') as HTMLInputElement, { target: { value: 'git@github.com:owner/repo2.git' } })
    fireEvent.click(screen.getByLabelText('Save repo'))
    await waitFor(() => expect(updateRepo).toHaveBeenCalledTimes(1))
    expect(updateRepo.mock.calls[0]![0]).toBe('myrepo')
    const body = updateRepo.mock.calls[0]![1] as { id?: string; new_id?: string; url: string; credential: { kind: string; vault_key: string } }
    // No id/new_id in the PUT body — ids are stable.
    expect(body.id).toBeUndefined()
    expect(body.new_id).toBeUndefined()
    expect(body.url).toBe('git@github.com:owner/repo2.git')
  })

  it('delete flow: trash → confirm → DELETE /api/repos/:id', async () => {
    deleteRepo.mockResolvedValue(true)
    reposState = [makeRepo({ id: 'myrepo' })]
    render(<ReposView />)
    fireEvent.click(screen.getByTestId('repo-row-myrepo'))
    fireEvent.click(screen.getByLabelText('Delete repo'))
    expect(screen.getByTestId('repo-delete-confirm')).toBeTruthy()
    fireEvent.click(screen.getByText('Confirm delete'))
    await waitFor(() => expect(deleteRepo).toHaveBeenCalledWith('myrepo'))
  })

  it('machine_user shows the username field; other kinds hide it', () => {
    reposState = []
    render(<ReposView />)
    fireEvent.click(screen.getByLabelText('New repo'))
    // Select "Bot Account" (machine_user) → username field appears.
    fireEvent.change(document.getElementById('repo-cred-kind') as HTMLSelectElement, { target: { value: 'machine_user' } })
    expect(document.getElementById('repo-username')).not.toBeNull()
    // Switch back to "Personal Access Token" (pat) → username field hidden.
    fireEvent.change(document.getElementById('repo-cred-kind') as HTMLSelectElement, { target: { value: 'pat' } })
    expect(document.getElementById('repo-username')).toBeNull()
  })

  it('has NO secret-value field (security invariant)', () => {
    // The editor form must never render an input whose name/id suggests a
    // secret VALUE (token/value/secret/password). The only credential
    // input is username (a bot account name) — never the secret itself.
    // The vault key is auto-generated from the repo id + credential kind.
    //
    // The PAT/Bot-token password field (`repo-token`, type="password") is
    // the deliberate, write-only exception: it IS a secret-value field by
    // design, but one that is sent to the server only on create/rotate and
    // never persisted in the UI state beyond the form's ephemeral
    // `form.token`. It is excluded from the forbidden-id check below.
    //
    // The PAT-source dropdown (`repo-token-source`, a <select>) is the
    // second sanctioned exception: its options are vault key NAMES from
    // `GET /api/secrets` (which never returns values). Picking one makes the
    // repo REFERENCE that vault entry — no secret value is read, sent, or
    // rendered. Render it here so the check covers it.
    reposState = []
    secretsState = ['GITHUB_PAT']
    render(<ReposView />)
    fireEvent.click(screen.getByLabelText('New repo'))
    const pane = screen.getByTestId('repo-form-new')
    const inputs = pane.querySelectorAll('input, textarea, select')
    const forbiddenIds = ['token', 'value', 'secret', 'password', 'credential_value', 'cred_value', 'secret_value']
    // Value-free by construction (see the comment block above).
    const sanctioned = new Set(['repo-token', 'repo-token-source'])
    for (const el of inputs) {
      const id = (el as HTMLElement).getAttribute('id') ?? ''
      const name = (el as HTMLElement).getAttribute('name') ?? ''
      if (sanctioned.has(id)) continue
      for (const bad of forbiddenIds) {
        expect(id.toLowerCase()).not.toContain(bad)
        expect(name.toLowerCase()).not.toContain(bad)
      }
    }
    // The dropdown's option VALUES are vault key names — never values.
    const source = document.getElementById('repo-token-source') as HTMLSelectElement
    expect(source).not.toBeNull()
    expect(Array.from(source.querySelectorAll('option')).map((o) => o.value)).toEqual(['', 'GITHUB_PAT'])
    // Sanity: the vault-key field is NOT present (auto-generated, no UI).
    expect(document.getElementById('repo-vault-key')).toBeNull()
  })

  // ── PAT / Bot-token password field (WU-D) ────────────────────────────────

  it('renders a password field when pat is selected', () => {
    reposState = []
    render(<ReposView />)
    fireEvent.click(screen.getByLabelText('New repo'))
    // Default credential kind is pat → password field is visible.
    const tokenEl = document.getElementById('repo-token') as HTMLInputElement
    expect(tokenEl).not.toBeNull()
    expect(tokenEl.type).toBe('password')
    // Switch to deploy_key → password field disappears.
    fireEvent.change(document.getElementById('repo-cred-kind') as HTMLSelectElement, { target: { value: 'deploy_key' } })
    expect(document.getElementById('repo-token')).toBeNull()
  })

  it('validation requires the token on create (submit with empty token + pat)', async () => {
    reposState = []
    render(<ReposView />)
    fireEvent.click(screen.getByLabelText('New repo'))
    fireEvent.change(document.getElementById('repo-id') as HTMLInputElement, { target: { value: 'myrepo' } })
    fireEvent.change(document.getElementById('repo-url') as HTMLInputElement, { target: { value: 'git@github.com:owner/repo.git' } })
    fireEvent.change(document.getElementById('repo-cred-kind') as HTMLSelectElement, { target: { value: 'pat' } })
    // Leave the token empty → submit.
    fireEvent.click(screen.getByLabelText('Create repo'))
    expect(screen.getByTestId('repo-form-error')).toBeTruthy()
    expect(screen.getByText(/PAT is required/i)).toBeTruthy()
    expect(createRepo).not.toHaveBeenCalled()
  })

  it('sends token in the payload on create (submit with token xyz)', async () => {
    createRepo.mockResolvedValue({ ok: true, repo: makeRepo({ id: 'myrepo' }) })
    reposState = []
    render(<ReposView />)
    fireEvent.click(screen.getByLabelText('New repo'))
    fireEvent.change(document.getElementById('repo-id') as HTMLInputElement, { target: { value: 'myrepo' } })
    fireEvent.change(document.getElementById('repo-url') as HTMLInputElement, { target: { value: 'git@github.com:owner/repo.git' } })
    fireEvent.change(document.getElementById('repo-cred-kind') as HTMLSelectElement, { target: { value: 'pat' } })
    fireEvent.change(document.getElementById('repo-token') as HTMLInputElement, { target: { value: 'xyz' } })
    fireEvent.click(screen.getByLabelText('Create repo'))
    await waitFor(() => expect(createRepo).toHaveBeenCalledTimes(1))
    const body = createRepo.mock.calls[0]![0] as { token?: string; credential: { kind: string } }
    expect(body.token).toBe('xyz')
    expect(body.credential.kind).toBe('pat')
  })

  it('clears the token on credential-kind switch', () => {
    reposState = []
    render(<ReposView />)
    fireEvent.click(screen.getByLabelText('New repo'))
    // pat is the default; type a token.
    fireEvent.change(document.getElementById('repo-token') as HTMLInputElement, { target: { value: 'xyz' } })
    expect((document.getElementById('repo-token') as HTMLInputElement).value).toBe('xyz')
    // Switch to deploy_key → token field disappears AND the token value
    // is cleared from form state (so it can't leak into a later payload).
    fireEvent.change(document.getElementById('repo-cred-kind') as HTMLSelectElement, { target: { value: 'deploy_key' } })
    expect(document.getElementById('repo-token')).toBeNull()
    // Switch back to pat → the field is empty (token was cleared).
    fireEvent.change(document.getElementById('repo-cred-kind') as HTMLSelectElement, { target: { value: 'pat' } })
    expect((document.getElementById('repo-token') as HTMLInputElement).value).toBe('')
  })

  // ── Reuse an existing vault secret (create form) ─────────────────────────

  it('create lists the vault secret names in the PAT-source dropdown', () => {
    // Deliberately unsorted input: the dropdown sorts names for scanability
    // and always offers the "paste a new token" option first.
    secretsState = ['GITHUB_PAT', 'GH_BOT_TOKEN']
    reposState = []
    render(<ReposView />)
    fireEvent.click(screen.getByLabelText('New repo'))
    const source = document.getElementById('repo-token-source') as HTMLSelectElement
    expect(source).not.toBeNull()
    expect(Array.from(source.querySelectorAll('option')).map((o) => o.value)).toEqual([
      '',
      'GH_BOT_TOKEN',
      'GITHUB_PAT',
    ])
    // Default selection = "paste a new token" → the password field is shown.
    expect(source.value).toBe('')
    expect(document.getElementById('repo-token')).not.toBeNull()
  })

  it('create references an existing vault secret without sending a token', async () => {
    createRepo.mockResolvedValue({ ok: true, repo: makeRepo({ id: 'myrepo' }) })
    secretsState = ['GITHUB_PAT']
    reposState = []
    render(<ReposView />)
    fireEvent.click(screen.getByLabelText('New repo'))
    fireEvent.change(document.getElementById('repo-id') as HTMLInputElement, { target: { value: 'myrepo' } })
    fireEvent.change(document.getElementById('repo-url') as HTMLInputElement, { target: { value: 'git@github.com:owner/repo.git' } })
    fireEvent.change(document.getElementById('repo-token-source') as HTMLSelectElement, { target: { value: 'GITHUB_PAT' } })
    // The password field is gone — the token value never leaves the vault.
    expect(document.getElementById('repo-token')).toBeNull()
    fireEvent.click(screen.getByLabelText('Create repo'))
    await waitFor(() => expect(createRepo).toHaveBeenCalledTimes(1))
    const body = createRepo.mock.calls[0]![0] as { token?: string; credential: { kind: string; vault_key: string } }
    // The repo references the chosen vault key by NAME; no token is sent
    // (so the vault is not written to at all).
    expect(body.credential.vault_key).toBe('GITHUB_PAT')
    expect(body.credential.kind).toBe('pat')
    expect(body.token).toBeUndefined()
  })

  it('selecting an existing vault secret clears a typed token', async () => {
    createRepo.mockResolvedValue({ ok: true, repo: makeRepo({ id: 'myrepo' }) })
    secretsState = ['GITHUB_PAT']
    reposState = []
    render(<ReposView />)
    fireEvent.click(screen.getByLabelText('New repo'))
    fireEvent.change(document.getElementById('repo-id') as HTMLInputElement, { target: { value: 'myrepo' } })
    fireEvent.change(document.getElementById('repo-url') as HTMLInputElement, { target: { value: 'git@github.com:owner/repo.git' } })
    // Type a token first, then decide to reuse a stored secret instead: the
    // typed token must not be sent alongside the selection.
    fireEvent.change(document.getElementById('repo-token') as HTMLInputElement, { target: { value: 'ghp_typed' } })
    fireEvent.change(document.getElementById('repo-token-source') as HTMLSelectElement, { target: { value: 'GITHUB_PAT' } })
    fireEvent.click(screen.getByLabelText('Create repo'))
    await waitFor(() => expect(createRepo).toHaveBeenCalledTimes(1))
    const body = createRepo.mock.calls[0]![0] as { token?: string; credential: { vault_key: string } }
    expect(body.token).toBeUndefined()
    expect(body.credential.vault_key).toBe('GITHUB_PAT')
  })

  it('switching the PAT source back to a new token restores an empty password field', () => {
    secretsState = ['GITHUB_PAT']
    reposState = []
    render(<ReposView />)
    fireEvent.click(screen.getByLabelText('New repo'))
    fireEvent.change(document.getElementById('repo-token-source') as HTMLSelectElement, { target: { value: 'GITHUB_PAT' } })
    expect(document.getElementById('repo-token')).toBeNull()
    // Back to "Paste a new token" → the field returns, empty.
    fireEvent.change(document.getElementById('repo-token-source') as HTMLSelectElement, { target: { value: '' } })
    expect((document.getElementById('repo-token') as HTMLInputElement).value).toBe('')
  })

  it('offers the PAT-source dropdown for machine_user too', () => {
    secretsState = ['GH_BOT_TOKEN']
    reposState = []
    render(<ReposView />)
    fireEvent.click(screen.getByLabelText('New repo'))
    fireEvent.change(document.getElementById('repo-cred-kind') as HTMLSelectElement, { target: { value: 'machine_user' } })
    expect(document.getElementById('repo-token-source')).not.toBeNull()
    expect(document.getElementById('repo-token')).not.toBeNull()
  })

  it('hides the PAT-source dropdown when the vault has no listable secrets', () => {
    // Vault locked / unconfigured → GET /api/secrets fails or is empty; the
    // form degrades to the plain password field (paste-a-token still works).
    secretsState = []
    secretsError = true
    reposState = []
    render(<ReposView />)
    fireEvent.click(screen.getByLabelText('New repo'))
    expect(document.getElementById('repo-token-source')).toBeNull()
    expect(document.getElementById('repo-token')).not.toBeNull()
  })

  it('does not offer the PAT-source dropdown when editing an existing repo', () => {
    // Editing keeps the repo's existing vault key (changing it would require
    // re-authenticating), so the picker is create-only.
    secretsState = ['GITHUB_PAT']
    reposState = [makeRepo({ id: 'myrepo', credential: { kind: 'pat', vault_key: 'GITHUB_PAT' } })]
    render(<ReposView />)
    fireEvent.click(screen.getByTestId('repo-row-myrepo'))
    expect(document.getElementById('repo-token-source')).toBeNull()
    expect(document.getElementById('repo-token')).not.toBeNull()
  })

  it('drops a picked vault secret when the credential kind changes (no secret overwrite)', async () => {
    // Deploy-key generation vhPut's the new passphrase under the credential's
    // vault key. If a stale PAT-secret selection survived the kind switch,
    // that passphrase would OVERWRITE the operator's PAT. The selection must
    // be dropped, leaving the deterministic seal-deploy_key-<id> key.
    createRepo.mockResolvedValue({ ok: true, repo: makeRepo({ id: 'myrepo' }) })
    secretsState = ['GITHUB_PAT']
    reposState = []
    render(<ReposView />)
    fireEvent.click(screen.getByLabelText('New repo'))
    fireEvent.change(document.getElementById('repo-id') as HTMLInputElement, { target: { value: 'myrepo' } })
    fireEvent.change(document.getElementById('repo-url') as HTMLInputElement, { target: { value: 'git@github.com:owner/repo.git' } })
    fireEvent.change(document.getElementById('repo-token-source') as HTMLSelectElement, { target: { value: 'GITHUB_PAT' } })
    fireEvent.change(document.getElementById('repo-cred-kind') as HTMLSelectElement, { target: { value: 'deploy_key' } })
    fireEvent.click(screen.getByLabelText('Create repo'))
    await waitFor(() => expect(createRepo).toHaveBeenCalledTimes(1))
    const body = createRepo.mock.calls[0]![0] as { token?: string; generate_key?: boolean; credential: { kind: string; vault_key: string } }
    expect(body.credential.kind).toBe('deploy_key')
    expect(body.credential.vault_key).toBe('seal-deploy_key-myrepo')
    expect(body.generate_key).toBe(true)
    expect(body.token).toBeUndefined()
  })

  it('editing a repo preserves its vault key (never rewrites it to the auto key)', async () => {
    // A repo created from the picker (or via an out-of-band /vault add)
    // references a custom vault key. Editing anything else about it — the URL
    // here — must not rewrite that key: the server would treat it as a
    // credential change and reject the PUT for want of a token (and the
    // referenced secret would be orphaned).
    updateRepo.mockResolvedValue(makeRepo({ id: 'myrepo', credential: { kind: 'pat', vault_key: 'GITHUB_PAT' } }))
    reposState = [makeRepo({ id: 'myrepo', credential: { kind: 'pat', vault_key: 'GITHUB_PAT' } })]
    render(<ReposView />)
    fireEvent.click(screen.getByTestId('repo-row-myrepo'))
    fireEvent.change(document.getElementById('repo-url') as HTMLInputElement, { target: { value: 'git@github.com:owner/renamed.git' } })
    fireEvent.click(screen.getByLabelText('Save repo'))
    await waitFor(() => expect(updateRepo).toHaveBeenCalledTimes(1))
    const body = updateRepo.mock.calls[0]![1] as { token?: string; credential: { kind: string; vault_key: string } }
    expect(body.credential.vault_key).toBe('GITHUB_PAT')
    expect(body.token).toBeUndefined()
  })

  it('editing + changing the credential kind uses the deterministic key for the new kind', async () => {
    updateRepo.mockResolvedValue(makeRepo({ id: 'myrepo', credential: { kind: 'machine_user', vault_key: 'seal-machine_user-myrepo' } }))
    reposState = [makeRepo({ id: 'myrepo', credential: { kind: 'pat', vault_key: 'GITHUB_PAT' } })]
    render(<ReposView />)
    fireEvent.click(screen.getByTestId('repo-row-myrepo'))
    fireEvent.change(document.getElementById('repo-cred-kind') as HTMLSelectElement, { target: { value: 'machine_user' } })
    fireEvent.change(document.getElementById('repo-username') as HTMLInputElement, { target: { value: 'seal-bot' } })
    fireEvent.change(document.getElementById('repo-token') as HTMLInputElement, { target: { value: 'ghp_new' } })
    fireEvent.click(screen.getByLabelText('Save repo'))
    await waitFor(() => expect(updateRepo).toHaveBeenCalledTimes(1))
    const body = updateRepo.mock.calls[0]![1] as { token?: string; credential: { kind: string; vault_key: string; username?: string } }
    expect(body.credential.kind).toBe('machine_user')
    expect(body.credential.vault_key).toBe('seal-machine_user-myrepo')
    expect(body.credential.username).toBe('seal-bot')
    expect(body.token).toBe('ghp_new')
  })
})
