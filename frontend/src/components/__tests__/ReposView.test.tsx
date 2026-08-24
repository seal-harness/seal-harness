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
    // credential kind defaults to deploy_key; vault_key is auto-generated.
    fireEvent.click(screen.getByLabelText('Create repo'))
    await waitFor(() => expect(createRepo).toHaveBeenCalledTimes(1))
    const body = createRepo.mock.calls[0]![0] as { id?: string; url: string; vcs_kind: string; credential: { kind: string; vault_key: string } }
    expect(body.id).toBe('myrepo')
    expect(body.url).toBe('git@github.com:owner/repo.git')
    expect(body.vcs_kind).toBe('github')
    expect(body.credential.kind).toBe('deploy_key')
    // vault_key is auto-generated: seal-<kind>-<id>
    expect(body.credential.vault_key).toBe('seal-deploy_key-myrepo')
  })

  it('create surfaces the backend error when the save fails', async () => {
    createRepo.mockResolvedValue({ ok: false, error: 'disallowed host: evil.example' })
    reposState = []
    render(<ReposView />)
    fireEvent.click(screen.getByLabelText('New repo'))
    fireEvent.change(document.getElementById('repo-id') as HTMLInputElement, { target: { value: 'myrepo' } })
    fireEvent.change(document.getElementById('repo-url') as HTMLInputElement, { target: { value: 'git@evil.example/o.git' } })
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
    reposState = []
    render(<ReposView />)
    fireEvent.click(screen.getByLabelText('New repo'))
    const pane = screen.getByTestId('repo-form-new')
    const inputs = pane.querySelectorAll('input, textarea, select')
    const forbiddenIds = ['token', 'value', 'secret', 'password', 'credential_value', 'cred_value', 'secret_value']
    for (const el of inputs) {
      const id = (el as HTMLElement).getAttribute('id') ?? ''
      const name = (el as HTMLElement).getAttribute('name') ?? ''
      // The write-only PAT/Bot-token password field is the sanctioned exception.
      if (id === 'repo-token') continue
      for (const bad of forbiddenIds) {
        expect(id.toLowerCase()).not.toContain(bad)
        expect(name.toLowerCase()).not.toContain(bad)
      }
    }
    // Sanity: the vault-key field is NOT present (auto-generated, no UI).
    expect(document.getElementById('repo-vault-key')).toBeNull()
  })

  // ── PAT / Bot-token password field (WU-D) ────────────────────────────────

  it('renders a password field when pat is selected', () => {
    reposState = []
    render(<ReposView />)
    fireEvent.click(screen.getByLabelText('New repo'))
    // Default credential kind is deploy_key → no token field.
    expect(document.getElementById('repo-token')).toBeNull()
    // Select "Personal Access Token" (pat) → password field appears.
    fireEvent.change(document.getElementById('repo-cred-kind') as HTMLSelectElement, { target: { value: 'pat' } })
    const tokenEl = document.getElementById('repo-token') as HTMLInputElement
    expect(tokenEl).not.toBeNull()
    expect(tokenEl.type).toBe('password')
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
    // Select pat, type a token.
    fireEvent.change(document.getElementById('repo-cred-kind') as HTMLSelectElement, { target: { value: 'pat' } })
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
})
