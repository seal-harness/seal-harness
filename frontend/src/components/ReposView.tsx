import { useEffect, useMemo, useRef, useState } from 'react'
import type { RepoCredentialKind, RepoInfo, RepoInput } from '../types'
import { REPO_CRED_LABELS } from '../types'
import {
  createRepo,
  deleteRepo,
  updateRepo,
  useRepos,
} from '../hooks/useApi'

// ── Helpers ─────────────────────────────────────────────────────────────

const labelStyle: React.CSSProperties = {
  fontSize: 12,
  fontWeight: 500,
  color: 'var(--text-muted)',
}

const inputStyle: React.CSSProperties = {
  fontSize: 14,
  padding: '6px 10px',
  backgroundColor: 'var(--bg-sunken)',
  border: '1px solid var(--border)',
  borderRadius: 'var(--radius-sm)',
  color: 'var(--text-primary)',
  outline: 'none',
  fontFamily: 'inherit',
  width: '100%',
}

function Row({
  label, htmlFor, children, hint,
}: { label: string; htmlFor: string; children: React.ReactNode; hint?: React.ReactNode }) {
  return (
    <div style={{ display: 'grid', gridTemplateColumns: '140px 1fr', alignItems: 'start', gap: 12 }}>
      {htmlFor ? (
        <label htmlFor={htmlFor} style={labelStyle}>{label}</label>
      ) : (
        <span style={labelStyle}>{label}</span>
      )}
      <div>
        {children}
        {hint && (
          <div style={{ fontSize: 11, color: 'var(--text-faint)', marginTop: 4 }}>{hint}</div>
        )}
      </div>
    </div>
  )
}

function emptyInput(): RepoInput {
  return { id: '', url: '', vcs_kind: 'github', credential: { kind: 'pat', vault_key: '' }, token: '' }
}

function repoToInput(r: RepoInfo): RepoInput {
  // The edit form does NOT pre-populate the token — it is not retrievable
  // from the vault via the API. The operator pastes a new token only when
  // rotating; an empty token field means "no change" (the PUT omits `token`
  // and the server leaves the vault entry untouched).
  return { id: r.id, url: r.url, vcs_kind: r.vcs_kind, credential: { ...r.credential }, token: '' }
}

/** Extract the GitHub deploy-keys settings URL from a repo URL.
 *  Returns null if the URL isn't a GitHub repo. Handles both
 *  git@github.com:owner/repo.git and https://github.com/owner/repo.git. */
function githubDeployKeysUrl(url: string): string | null {
  // git@github.com:owner/repo.git → owner/repo.git
  let path: string | null = null
  if (url.startsWith('git@github.com:')) {
    path = url.slice('git@github.com:'.length)
  } else if (url.startsWith('https://github.com/')) {
    path = url.slice('https://github.com/'.length)
  } else if (url.startsWith('http://github.com/')) {
    path = url.slice('http://github.com/'.length)
  }
  if (!path) return null
  // Strip trailing .git
  path = path.replace(/\.git$/, '')
  // Remove trailing slash
  path = path.replace(/\/$/, '')
  return `https://github.com/${path}/settings/keys`
}

/** Auto-generate the vault key from the repo id + credential kind. The
 *  vault key is deterministic (same id + kind → same key) so the user never
 *  needs to type it. Pattern: `seal-<kind>-<id>` (e.g. `seal-pat-myrepo`,
 *  `seal-deploy_key-myrepo`, `seal-machine_user-myrepo`). */
function autoVaultKey(id: string, kind: RepoCredentialKind): string {
  return `seal-${kind}-${id}`
}

// ── Component ───────────────────────────────────────────────────────────

/** The source-control repos CRUD view. Lists every repo on the left; the
 *  right pane is an editor (create or edit). Creating POSTs /api/repos;
 *  editing PUTs /api/repos/:id (ids are stable — NO new_id); the trash
 *  button DELETEs. The list re-fetches after every mutation (and on the
 *  `repos-changed` WS frame).
 *
 *  SECURITY INVARIANT: the credential descriptor stored here is a vault
 *  key NAME only — the secret value lives in the Seal vault and is NEVER
 *  rendered in this UI. The vault key is auto-generated from the repo id +
 *  credential kind (no user-facing field for it). The editor exposes
 *  `credential.username` (bot-account name only, machine_user), never a
 *  token/secret/password field. */
export function ReposView() {
  const { repos, loaded, error, refresh } = useRepos()

  const [editing, setEditing] = useState<string | null>(null)
  const [creating, setCreating] = useState(false)
  const [form, setForm] = useState<RepoInput>(emptyInput())
  const [submitting, setSubmitting] = useState(false)
  const [formError, setFormError] = useState<string | null>(null)
  const [confirmingDelete, setConfirmingDelete] = useState<string | null>(null)

  // Ref holding the latest `repos` list so the seed effect can read it
  // without re-running on every poll tick.
  const reposRef = useRef(repos)
  reposRef.current = repos

  // Seed the form ONLY when the user picks a repo (or starts creating).
  useEffect(() => {
    if (creating) {
      setForm(emptyInput())
      setFormError(null)
      return
    }
    if (editing) {
      const r = reposRef.current.find((x) => x.id === editing)
      if (r) {
        setForm(repoToInput(r))
        setFormError(null)
      }
    }
  }, [editing, creating])

  const selected = useMemo(
    () => (editing ? repos.find((r) => r.id === editing) ?? null : null),
    [editing, repos],
  )

  const validateForm = (): string | null => {
    const id = (form.id ?? '').trim()
    if (id.length === 0) return 'id is required'
    if (!/^[A-Za-z0-9_-]+$/.test(id)) return 'id must be [A-Za-z0-9_-]+ (no spaces, slashes, or dots)'
    if (!(form.url ?? '').trim()) return 'url is required'
    if (form.credential.kind === 'machine_user' && !(form.credential.username ?? '').trim()) {
      return 'username is required for a Bot Account (machine_user)'
    }
    // The PAT / bot-token is required on CREATE for pat/machine_user (the
    // server must vhPut it into the vault — there's no other way to get the
    // token in). On EDIT the token is optional (empty = no change / no vault
    // touch — the operator only pastes a new token to rotate).
    if (creating && (form.credential.kind === 'pat' || form.credential.kind === 'machine_user')) {
      if (!(form.token ?? '').trim()) {
        return form.credential.kind === 'pat' ? 'PAT is required' : 'Bot token is required'
      }
    }
    return null
  }

  const handleSubmit = async () => {
    const verr = validateForm()
    if (verr) { setFormError(verr); return }
    setSubmitting(true)
    setFormError(null)
    const trimmedId = (form.id ?? '').trim()
    const url = (form.url ?? '').trim()
    const vaultKey = autoVaultKey(trimmedId, form.credential.kind)
    const username = form.credential.username?.trim()
    if (creating) {
      const token = form.token?.trim()
      const payload: RepoInput = {
        id: trimmedId,
        url,
        vcs_kind: form.vcs_kind,
        credential: {
          kind: form.credential.kind,
          vault_key: vaultKey,
          ...(form.credential.kind === 'machine_user' && username ? { username } : {}),
        },
        // Auto-generate a deploy keypair when the credential kind is
        // deploy_key (the server runs ssh-keygen + stores the encrypted
        // keyfile + the passphrase in the vault).
        ...(form.credential.kind === 'deploy_key' ? { generate_key: true } : {}),
        // Write-only: send the PAT/bot-token for pat/machine_user so the
        // server vhPut's it into the vault under vaultKey. (Validation
        // already guaranteed a non-empty token for these kinds on create.)
        ...((form.credential.kind === 'pat' || form.credential.kind === 'machine_user') && token ? { token } : {}),
      }
      const res = await createRepo(payload)
      setSubmitting(false)
      if (res.ok) {
        refresh()
        setCreating(false)
        setEditing(res.repo.id)
      } else {
        setFormError(res.error)
      }
    } else if (editing) {
      // PUT: id from path; ids are stable — NO new_id.
      const token = form.token?.trim()
      const payload: RepoInput = {
        url,
        vcs_kind: form.vcs_kind,
        credential: {
          kind: form.credential.kind,
          vault_key: vaultKey,
          ...(form.credential.kind === 'machine_user' && username ? { username } : {}),
        },
        // On edit, send the token ONLY if non-empty (rotation). An empty
        // token means "no change" — the server leaves the vault entry
        // untouched (assuming the credential kind is unchanged).
        ...(token ? { token } : {}),
      }
      const res = await updateRepo(editing, payload)
      setSubmitting(false)
      if (res) {
        refresh()
        setEditing(res.id)
      } else {
        setFormError('Save failed — check the backend is reachable.')
      }
    }
  }

  const handleDelete = async (id: string) => {
    const ok = await deleteRepo(id)
    if (ok) {
      if (editing === id) setEditing(null)
      if (confirmingDelete === id) setConfirmingDelete(null)
      refresh()
    }
  }

  const handleNew = () => {
    setEditing(null)
    setCreating(true)
  }

  const handleCancel = () => {
    setCreating(false)
    setEditing(null)
    setFormError(null)
  }

  const credKind = form.credential.kind

  return (
    <div className="flex flex-1 min-h-0" style={{ background: 'var(--bg-base)' }}>
      {/* List pane */}
      <div
        className="shrink-0 flex flex-col"
        style={{
          width: 280,
          background: 'var(--bg-surface)',
          borderRight: '1px solid var(--border)',
        }}
      >
        <div
          className="flex items-center justify-between px-3 py-2"
          style={{ borderBottom: '1px solid var(--border)' }}
        >
          <span
            className="text-xs font-semibold uppercase"
            style={{ color: 'var(--text-muted)', letterSpacing: '0.08em' }}
          >
            Repos ({repos.length})
          </span>
          <button
            type="button"
            className="btn btn-ghost flex items-center justify-center"
            style={{ width: 22, height: 22, padding: 0, fontSize: 14, lineHeight: 1 }}
            onClick={handleNew}
            aria-label="New repo"
            title="New repo"
          >
            +
          </button>
        </div>
        <div className="flex-1 overflow-y-auto sidebar-scroll">
          {!loaded && (
            <div className="px-3 py-2 text-xs" style={{ color: 'var(--text-faint)' }}>
              Loading…
            </div>
          )}
          {loaded && repos.length === 0 && (
            <div className="px-3 py-2 text-xs" style={{ color: 'var(--text-faint)' }}>
              No repos registered. Click &lsquo;New&rsquo; to add one.
            </div>
          )}
          {repos.map((r) => {
            const isActive = (creating ? false : editing === r.id) && !confirmingDelete
            return (
              <div
                key={r.id}
                data-testid={`repo-row-${r.id}`}
                className={`agent-row px-3 py-2 cursor-pointer${isActive ? ' selected' : ''}`}
                onClick={() => {
                  if (confirmingDelete === r.id) setConfirmingDelete(null)
                  setCreating(false)
                  setEditing(r.id)
                }}
              >
                <div
                  className="text-sm truncate"
                  style={{ color: 'var(--text-primary)', letterSpacing: 'var(--tracking-tight)' }}
                  title={r.id}
                >
                  {r.id}
                </div>
                <div
                  className="text-xs mt-0.5 truncate"
                  style={{ color: 'var(--text-faint)' }}
                  title={r.url}
                >
                  {r.url}
                </div>
                <div
                  className="text-xs mt-0.5 truncate"
                  style={{ color: 'var(--text-muted)' }}
                  title={REPO_CRED_LABELS[r.credential.kind]}
                >
                  {REPO_CRED_LABELS[r.credential.kind]}
                </div>
              </div>
            )
          })}
        </div>
      </div>

      {/* Editor / detail pane */}
      <div className="flex-1 overflow-y-auto" style={{ padding: '24px 32px' }}>
        {error && (
          <div
            data-testid="repos-load-error"
            style={{ fontSize: 12, color: 'var(--needs-input)', marginBottom: 12 }}
          >
            Failed to load repos — the backend may be unreachable.
          </div>
        )}
        {!creating && !selected && (
          <div
            className="flex flex-col items-center justify-center"
            style={{ height: '100%', color: 'var(--text-faint)', gap: 8 }}
          >
            <div className="text-sm">Select a repo to edit, or click + to create one.</div>
          </div>
        )}
        {(creating || selected) && (
          <div
            className="flex flex-col gap-4"
            style={{ maxWidth: 720, margin: '0 auto' }}
            data-testid={creating ? 'repo-form-new' : `repo-form-${editing ?? ''}`}
          >
            <div className="flex items-center gap-2">
              <span className="text-lg font-semibold" style={{ color: 'var(--text-primary)' }}>
                {creating ? 'New repo' : (selected?.id || 'Repo')}
              </span>
            </div>

            <Row label="Id" htmlFor="repo-id" hint="Canonical id ([A-Za-z0-9_-]+). Stable — editing it is disabled.">
              <input
                id="repo-id"
                type="text"
                value={form.id ?? ''}
                onChange={(e) => setForm((f) => ({ ...f, id: e.target.value }))}
                style={inputStyle}
                placeholder="e.g. myrepo"
                autoComplete="off"
                disabled={!creating}
              />
            </Row>

            <Row label="URL" htmlFor="repo-url" hint="The clone URL (HTTPS or SSH).">
              <input
                id="repo-url"
                type="text"
                value={form.url ?? ''}
                onChange={(e) => setForm((f) => ({ ...f, url: e.target.value }))}
                style={inputStyle}
                placeholder="git@github.com:owner/repo.git"
                autoComplete="off"
              />
            </Row>

            <Row label="VCS kind" htmlFor="repo-vcs-kind" hint="The version-control system.">
              <select
                id="repo-vcs-kind"
                value={form.vcs_kind}
                onChange={(e) => setForm((f) => ({ ...f, vcs_kind: e.target.value as 'git' | 'github' }))}
                style={inputStyle}
              >
                <option value="github">github</option>
                <option value="git">git</option>
              </select>
            </Row>

            <Row label="Credential" htmlFor="repo-cred-kind" hint="How Seal authenticates to the repo. The secret value lives in the vault.">
              <select
                id="repo-cred-kind"
                value={form.credential.kind}
                onChange={(e) => {
                  const kind = e.target.value as RepoCredentialKind
                  setForm((f) => ({
                    ...f,
                    // Clear the token when switching credential kinds so a
                    // PAT typed then switched to deploy_key doesn't leak into
                    // a later payload. (The token is create-only/rotate-only;
                    // it has no meaning under a different credential kind.)
                    token: '',
                    credential: {
                      kind,
                      vault_key: f.credential.vault_key,
                      // Drop username when switching away from machine_user.
                      ...(kind === 'machine_user' && f.credential.username ? { username: f.credential.username } : {}),
                    },
                  }))
                }}
                style={inputStyle}
              >
                {(Object.keys(REPO_CRED_LABELS) as RepoCredentialKind[]).map((k) => (
                  <option key={k} value={k}>{REPO_CRED_LABELS[k]}</option>
                ))}
              </select>
            </Row>

            {credKind === 'machine_user' && (
              <Row label="Username" htmlFor="repo-username" hint="The bot account username (machine_user only).">
                <input
                  id="repo-username"
                  type="text"
                  value={form.credential.username ?? ''}
                  onChange={(e) => setForm((f) => ({ ...f, credential: { ...f.credential, username: e.target.value } }))}
                  style={inputStyle}
                  placeholder="bot-account"
                  autoComplete="off"
                />
              </Row>
            )}

            {/* PAT / Bot-token password field — write-only. Shown for the
                two token-bearing credential kinds (pat, machine_user). The
                field is the primary interaction; the advisory note (below)
                moves under it so the field is prominent, not the note. On
                edit the field is empty (no pre-population — the token is not
                retrievable from the vault via the API); a non-empty value
                rotates the vault entry. */}
            {(credKind === 'pat' || credKind === 'machine_user') && (
              <Row
                label={credKind === 'pat' ? 'PAT' : 'Bot token'}
                htmlFor="repo-token"
                hint={creating
                  ? undefined
                  : 'Paste a new token to rotate (leave empty to keep the existing one).'}
              >
                <input
                  id="repo-token"
                  type="password"
                  value={form.token ?? ''}
                  onChange={(e) => setForm((f) => ({ ...f, token: e.target.value }))}
                  style={inputStyle}
                  placeholder={creating
                    ? (credKind === 'pat' ? 'ghp_...' : 'ghp_...')
                    : 'Paste new token to rotate (leave empty to keep)'}
                  autoComplete="off"
                />
              </Row>
            )}

            {!creating && selected?.deploy_key_public && (() => {
              const deployKeysUrl = githubDeployKeysUrl(selected.url)
              return (
              <Row label="Deploy key" htmlFor="" hint={
                deployKeysUrl
                  ? <>The public key for this repo's deploy key. Add it to your <a href={deployKeysUrl} target="_blank" rel="noopener noreferrer" style={{ color: 'var(--accent)', textDecoration: 'underline' }}>GitHub repo&apos;s Deploy Keys settings</a>.</>
                  : 'The public key for this repo\'s deploy key. Add it to your repo\'s Deploy Keys settings.'
              }>
                <div>
                  <pre
                    data-testid="deploy-key-public"
                    className="text-xs"
                    style={{
                      background: 'var(--bg-base)',
                      border: '1px solid var(--border)',
                      borderRadius: 4,
                      padding: 8,
                      whiteSpace: 'pre-wrap',
                      wordBreak: 'break-all',
                      color: 'var(--text-primary)',
                      margin: 0,
                      cursor: 'default',
                      userSelect: 'all',
                    }}
                  >
                    {selected.deploy_key_public}
                  </pre>
                  <button
                    type="button"
                    className="btn btn-ghost mt-1"
                    onClick={() => {
                      const text = selected.deploy_key_public ?? ''
                      if (navigator.clipboard?.writeText) {
                        void navigator.clipboard.writeText(text)
                      } else {
                        // Fallback for non-secure contexts (HTTP / non-localhost).
                        const ta = document.createElement('textarea')
                        ta.value = text
                        ta.style.position = 'fixed'
                        ta.style.opacity = '0'
                        document.body.appendChild(ta)
                        ta.select()
                        try { document.execCommand('copy') } catch { /* noop */ }
                        document.body.removeChild(ta)
                      }
                    }}
                    style={{ fontSize: 11 }}
                  >
                    Copy
                  </button>
                </div>
              </Row>
              )
            })()}

            {formError && (
              <div
                data-testid="repo-form-error"
                style={{ fontSize: 12, color: 'var(--needs-input)' }}
              >
                {formError}
              </div>
            )}

            <div
              className="flex flex-col gap-2"
              style={{ borderTop: '1px solid var(--border)', paddingTop: 16 }}
            >
              <div className="flex gap-2">
                <button
                  type="button"
                  className="btn btn-primary px-3 py-2 rounded-lg text-sm font-medium"
                  onClick={handleSubmit}
                  disabled={submitting}
                  aria-label={creating ? 'Create repo' : 'Save repo'}
                >
                  {creating ? 'Create' : 'Save'}
                </button>
                <button
                  type="button"
                  className="btn btn-ghost px-3 py-2 rounded-lg text-sm font-medium"
                  onClick={handleCancel}
                >
                  Cancel
                </button>
                {!creating && selected && confirmingDelete !== selected.id && (
                  <button
                    type="button"
                    className="btn btn-danger-ghost px-3 py-2 rounded-lg text-sm font-medium"
                    style={{ marginLeft: 'auto' }}
                    onClick={() => setConfirmingDelete(selected.id)}
                    aria-label="Delete repo"
                  >
                    Delete
                  </button>
                )}
              </div>
              {!creating && selected && confirmingDelete === selected.id && (
                <div className="flex flex-col gap-2" data-testid="repo-delete-confirm">
                  <span className="text-sm" style={{ color: 'var(--needs-input)' }}>
                    Delete repo <strong>{selected.id}</strong>? This cannot be undone.
                  </span>
                  <div className="flex gap-2">
                    <button
                      type="button"
                      className="btn btn-danger-ghost px-3 py-2 rounded-lg text-sm font-medium"
                      style={{ background: 'var(--needs-input)', color: 'var(--text-primary)' }}
                      onClick={() => void handleDelete(selected.id)}
                      aria-label="Confirm delete"
                    >
                      Confirm delete
                    </button>
                    <button
                      type="button"
                      className="btn btn-ghost px-3 py-2 rounded-lg text-sm font-medium"
                      onClick={() => setConfirmingDelete(null)}
                    >
                      Cancel
                    </button>
                  </div>
                </div>
              )}
            </div>
          </div>
        )}
      </div>
    </div>
  )
}
