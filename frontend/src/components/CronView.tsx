import { useEffect, useMemo, useRef, useState } from 'react'
import {
  createCronJob,
  deleteCronJob,
  fetchCronJob,
  fetchProviderModels,
  updateCronJob,
  useAgentDefs,
  useConfiguredProviders,
  useCronJobs,
} from '../hooks/useApi'
import { agentOptionLabel, groupAgents } from '../lib/agentGroups'
import { CustomModelCombobox, ProviderSelect } from './ProviderModelFields'
import type { CronJobDetail, CronJobSummary } from '../types'

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

// ── Component ───────────────────────────────────────────────────────────

/** The cron jobs CRUD view. Lists every job on the left with schedule and
 *  enabled state; the right pane is an editor (create or edit). Creating
 *  POSTs /api/cron; editing PUTs /api/cron/:id; the trash button DELETEs.
 *  Jobs are created disabled by default — the operator enables them as a
 *  separate, explicit action (design D3). */
export function CronView() {
  const { jobs, loaded, error, refresh } = useCronJobs()
  const { agents, loaded: agentsLoaded } = useAgentDefs()
  const { providers, loaded: providersLoaded } = useConfiguredProviders()

  const [editing, setEditing] = useState<string | null>(null)
  const [creating, setCreating] = useState(false)
  const [name, setName] = useState('')
  const [schedule, setSchedule] = useState('')
  const [timezone, setTimezone] = useState('')
  const [prompt, setPrompt] = useState('')
  const [agentDefId, setAgentDefId] = useState('')
  const [provider, setProvider] = useState('')
  const [model, setModel] = useState('')
  // Model suggestions for the picked provider. `modelsLoading` lets the
  // combobox show a loading hint instead of an empty list while the fetch is
  // in flight; `modelsFor` guards against a stale response landing after the
  // operator has already flipped to a different provider.
  const [modelOptions, setModelOptions] = useState<string[]>([])
  const [modelsLoading, setModelsLoading] = useState(false)
  const modelsFor = useRef<string>('')
  const [enabled, setEnabled] = useState(false)
  const [oneShot, setOneShot] = useState(false)
  const [submitting, setSubmitting] = useState(false)
  const [formError, setFormError] = useState<string | null>(null)
  const [confirmingDelete, setConfirmingDelete] = useState<string | null>(null)

  // Detail (with next_fire) for the selected job.
  const [detail, setDetail] = useState<CronJobDetail | null>(null)

  const jobsRef = useRef(jobs)
  jobsRef.current = jobs

  // Fetch the detail (with next_fire) when a job is selected.
  useEffect(() => {
    if (editing && !creating) {
      fetchCronJob(editing).then((d) => setDetail(d))
    } else {
      setDetail(null)
    }
  }, [editing, creating])

  // Seed the form when the user picks a job to edit.
  useEffect(() => {
    if (editing && !creating) {
      const job = jobsRef.current.find((j) => j.id === editing)
      if (job) {
        setName(job.name)
        setSchedule(job.schedule)
        setTimezone(job.timezone ?? '')
        setPrompt(job.prompt)
        setAgentDefId(job.agent_def_id ?? '')
        setProvider(job.provider ?? '')
        setModel(job.model ?? '')
        setEnabled(job.enabled)
        setOneShot(job.one_shot)
        setFormError(null)
      }
    } else if (creating) {
      setName('')
      setSchedule('')
      setTimezone('')
      setPrompt('')
      setAgentDefId('')
      setProvider('')
      setModel('')
      setEnabled(false) // D3: create defaults to disabled
      setOneShot(false)
      setFormError(null)
    }
  }, [editing, creating])

  // Fetch the model suggestions for the selected provider. Configured
  // `models` win; otherwise ask the provider live. `fetchProviderModels`
  // never throws and returns [] on any failure, so the combobox always stays
  // usable for free-text entry. The `cancelled` flag drops a response for a
  // provider the operator has already switched away from.
  useEffect(() => {
    if (!provider) {
      setModelOptions([])
      setModelsLoading(false)
      return
    }
    const info = providers.find((p) => p.name === provider)
    const configured = info?.models ?? []
    if (configured.length > 0) {
      setModelOptions(configured)
      setModelsLoading(false)
      return
    }
    let cancelled = false
    setModelsLoading(true)
    modelsFor.current = provider
    fetchProviderModels(provider).then((rows) => {
      if (cancelled || modelsFor.current !== provider) return
      setModelOptions(rows.map((r) => r.name))
      setModelsLoading(false)
    })
    return () => { cancelled = true }
  }, [provider, providers])

  const sortedJobs = useMemo(() => {
    return [...jobs].sort((a, b) => a.name.localeCompare(b.name))
  }, [jobs])
  const agentGroups = useMemo(() => groupAgents(agents), [agents])

  // The provider picker's options. A stored provider that no longer resolves
  // to a configured provider is kept selectable as "(missing)", mirroring the
  // agent picker above: opening and saving a job must not silently clear a
  // value the operator never touched. While the list is still loading we
  // cannot tell "missing" from "not fetched yet", so no synthetic entry is
  // added until it has loaded.
  const providerOptions = useMemo(() => {
    const base = providers.filter((p) => p.configured !== false)
    if (!providersLoaded || provider === '') return base
    if (base.some((p) => p.name === provider)) return base
    return [...base, { name: provider, missing: true }]
  }, [providers, providersLoaded, provider])

  async function handleSubmit() {
    setSubmitting(true)
    setFormError(null)
    const input = {
      name,
      schedule,
      timezone: timezone || undefined,
      prompt,
      agent_def_id: agentDefId || undefined,
      // Provider/model are optional: no provider means "Seal's configured
      // default". An empty model likewise omits the key, so the job follows
      // the configured default model rather than pinning one. On edit an
      // emptied provider sends "" — the wire signal that clears the field.
      provider: provider || (creating ? undefined : ''),
      model: model || (creating ? undefined : ''),
      enabled,
      one_shot: oneShot,
    }
    if (creating) {
      const res = await createCronJob(input)
      if (res.ok) {
        setCreating(false)
        setEditing(res.job.id)
        refresh()
      } else {
        setFormError(res.error)
      }
    } else if (editing) {
      const res = await updateCronJob(editing, input)
      if (res.ok) {
        setFormError(null)
        setDetail(res.job)
        refresh()
      } else {
        setFormError(res.error)
      }
    }
    setSubmitting(false)
  }

  async function handleDelete(id: string) {
    await deleteCronJob(id)
    setConfirmingDelete(null)
    if (editing === id) {
      setEditing(null)
    }
    refresh()
  }

  async function handleToggleEnabled(job: CronJobSummary) {
    const res = await updateCronJob(job.id, { enabled: !job.enabled })
    if (res.ok) {
      setDetail(res.job)
      refresh()
      setEnabled(res.job.enabled)
    } else {
      setFormError(res.error)
    }
  }

  if (error && !loaded) {
    return <div style={{ padding: 20, color: 'var(--text-muted)' }}>Failed to load cron jobs.</div>
  }

  return (
    <div style={{ display: 'flex', flex: 1, minHeight: 0 }}>
      {/* List pane */}
      <div style={{
        width: 280,
        borderRight: '1px solid var(--border)',
        overflowY: 'auto',
        flexShrink: 0,
      }}>
        <div style={{
          padding: '10px 12px',
          borderBottom: '1px solid var(--border)',
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'space-between',
        }}>
          <span style={{ fontSize: 13, fontWeight: 600 }}>Cron Jobs</span>
          <button
            type="button"
            className="btn btn-ghost flex items-center justify-center"
            style={{ width: 22, height: 22, padding: 0, fontSize: 14, lineHeight: 1 }}
            onClick={() => { setCreating(true); setEditing(null) }}
            aria-label="New cron job"
            title="New cron job"
          >
            +
          </button>
        </div>
        {sortedJobs.length === 0 && loaded && (
          <div style={{ padding: 12, fontSize: 12, color: 'var(--text-faint)' }}>
            No cron jobs defined.
          </div>
        )}
        {/* Legend */}
        <div style={{
          padding: '4px 12px 6px',
          display: 'flex',
          gap: 12,
          fontSize: 10,
          color: 'var(--text-faint)',
        }}>
          <span style={{ display: 'flex', alignItems: 'center', gap: 4 }}>
            <span style={{ width: 7, height: 7, borderRadius: '50%', backgroundColor: 'var(--success)' }} />
            Enabled
          </span>
          <span style={{ display: 'flex', alignItems: 'center', gap: 4 }}>
            <span style={{ width: 7, height: 7, borderRadius: '50%', border: '1.5px solid var(--text-faint)', boxSizing: 'border-box' }} />
            Disabled
          </span>
        </div>
        {sortedJobs.map((job) => (
          <div
            key={job.id}
            onClick={() => { setEditing(job.id); setCreating(false) }}
            style={{
              padding: '8px 12px',
              cursor: 'pointer',
              borderBottom: '1px solid var(--border)',
              backgroundColor: editing === job.id && !creating ? 'var(--bg-sunken)' : 'transparent',
            }}
          >
            <div style={{
              fontSize: 13,
              fontWeight: 500,
              color: 'var(--text-primary)',
              display: 'flex',
              alignItems: 'center',
              gap: 6,
            }}>
              <span style={{
                width: 9,
                height: 9,
                borderRadius: '50%',
                flexShrink: 0,
                backgroundColor: job.enabled ? 'var(--success)' : 'transparent',
                border: job.enabled ? 'none' : '1.5px solid var(--text-faint)',
                boxSizing: 'border-box',
              }} />
              {job.name}
            </div>
            <div style={{ fontSize: 11, color: 'var(--text-muted)', marginTop: 2 }}>
              {job.schedule}
              {job.consecutive_failures > 0 && (
                <span style={{ color: 'var(--needs-input)', marginLeft: 8 }}>
                  {job.consecutive_failures} failures
                </span>
              )}
            </div>
          </div>
        ))}
      </div>

      {/* Editor pane */}
      <div style={{ flex: 1, overflowY: 'auto', padding: 20 }}>
        {!editing && !creating && (
          <div style={{ color: 'var(--text-muted)', fontSize: 14 }}>
            Select a cron job or create a new one.
          </div>
        )}

        {(editing || creating) && (
          <div style={{ maxWidth: 600, display: 'flex', flexDirection: 'column', gap: 16 }}>
            <h3 style={{ margin: 0, fontSize: 16 }}>
              {creating ? 'New Cron Job' : 'Edit Cron Job'}
            </h3>

            {/* Status badge */}
            {!creating && detail && (
              <div style={{ display: 'flex', alignItems: 'center', gap: 6, marginTop: -8 }}>
                <span style={{
                  width: 8,
                  height: 8,
                  borderRadius: '50%',
                  flexShrink: 0,
                  backgroundColor: detail.enabled ? 'var(--success)' : 'transparent',
                  border: detail.enabled ? 'none' : '1.5px solid var(--text-faint)',
                  boxSizing: 'border-box',
                }} />
                <span style={{
                  fontSize: 12,
                  fontWeight: 600,
                  color: detail.enabled ? 'var(--success)' : 'var(--text-faint)',
                }}>
                  {detail.enabled ? 'Enabled' : 'Disabled'}
                </span>
              </div>
            )}

            {formError && (
              <div style={{
                padding: '8px 12px',
                backgroundColor: 'var(--needs-input-bg)',
                border: '1px solid var(--needs-input)',
                borderRadius: 'var(--radius-sm)',
                fontSize: 13,
                color: 'var(--needs-input)',
              }}>
                {formError}
              </div>
            )}

            <Row label="Name" htmlFor="cron-name">
              <input
                id="cron-name"
                style={inputStyle}
                value={name}
                onChange={(e) => setName(e.target.value)}
                placeholder="Daily Code Review"
              />
            </Row>

            <Row label="Schedule" htmlFor="cron-schedule" hint="5-field cron expression, e.g. 0 9 * * 1-5">
              <input
                id="cron-schedule"
                style={inputStyle}
                value={schedule}
                onChange={(e) => setSchedule(e.target.value)}
                placeholder="0 9 * * 1-5"
              />
            </Row>

            <Row label="Timezone" htmlFor="cron-timezone" hint="IANA timezone (optional, defaults to host local)">
              <input
                id="cron-timezone"
                style={inputStyle}
                value={timezone}
                onChange={(e) => setTimezone(e.target.value)}
                placeholder="America/New_York"
              />
            </Row>

            <Row label="Prompt" htmlFor="cron-prompt">
              <textarea
                id="cron-prompt"
                style={{ ...inputStyle, minHeight: 80, resize: 'vertical' }}
                value={prompt}
                onChange={(e) => setPrompt(e.target.value)}
                placeholder="Review yesterday's commits and summarize changes"
              />
            </Row>

            <Row
              label="Agent"
              htmlFor="cron-agent"
              hint="The agent definition that runs this job's prompt. The unset option uses the configured default agent."
            >
              {/* A constrained picker, not free text: the job's
                  agent_def_id must name an agent def that exists, and the
                  backend validates it with mkAgentDefId. Grouping mirrors the
                  Agents view so the two surfaces present the same order. */}
              <select
                id="cron-agent"
                style={inputStyle}
                className="composer-select"
                value={agentDefId}
                onChange={(e) => setAgentDefId(e.target.value)}
              >
                <option value="">
                  {agentsLoaded ? '(use configured default)' : 'Loading…'}
                </option>
                {agentGroups.map((grp) =>
                  grp.ungrouped ? (
                    grp.agents.map((a) => (
                      <option key={a.id} value={a.id}>{agentOptionLabel(a)}</option>
                    ))
                  ) : (
                    <optgroup key={grp.label} label={grp.label}>
                      {grp.agents.map((a) => (
                        <option key={a.id} value={a.id}>{agentOptionLabel(a)}</option>
                      ))}
                    </optgroup>
                  ),
                )}
                {/* Keep an id that no longer resolves to a def selectable, so
                    opening and saving a job cannot silently clear its agent.
                    The backend re-validates the id on write; this only keeps
                    the stored value visible and unchanged. While the list is
                    still loading we cannot tell "missing" from "not fetched
                    yet", so the label stays bare until it has loaded. */}
                {agentDefId !== '' && !agents.some((a) => a.id === agentDefId) && (
                  <option value={agentDefId}>
                    {agentsLoaded ? `${agentDefId} (missing)` : agentDefId}
                  </option>
                )}
              </select>
            </Row>

            <Row
              label="Provider"
              htmlFor="cron-provider"
              hint="Optional override. Unset uses Seal's configured default provider."
            >
              <ProviderSelect
                id="cron-provider"
                value={provider}
                onChange={(v) => {
                  setProvider(v)
                  // Provider and model are independent, but a model chosen for
                  // one provider is rarely valid on another, and the model
                  // control is disabled without a provider. Clearing it here
                  // keeps the pair consistent without pinning a model the
                  // operator never typed.
                  if (v === '') setModel('')
                }}
                providers={providerOptions}
                loading={!providersLoaded}
                showDefaultOption
              />
            </Row>

            <Row
              label="Model"
              htmlFor="cron-model"
              hint="Optional override. Unset uses Seal's configured default model."
            >
              {provider === '' ? (
                // No provider yet, so the model cannot be meaningfully
                // edited. `value` still shows a stored model so the form
                // never hides a value it will submit (a job may legitimately
                // carry a model with no provider; see the backend D4 note).
                <input
                  id="cron-model"
                  type="text"
                  value={model}
                  disabled
                  readOnly
                  style={inputStyle}
                  placeholder="(use configured default)"
                />
              ) : (
                <CustomModelCombobox
                  id="cron-model"
                  value={model}
                  onChange={setModel}
                  options={modelOptions}
                  placeholder={
                    modelsLoading
                      ? 'Loading models…'
                      : 'model id (pick a suggestion or type your own)'
                  }
                  testId="cron-model-list"
                />
              )}
            </Row>

            <Row label="Enabled" htmlFor="cron-enabled">
              <label style={{ display: 'flex', alignItems: 'center', gap: 8, cursor: 'pointer' }}>
                <input
                  id="cron-enabled"
                  type="checkbox"
                  checked={enabled}
                  onChange={(e) => setEnabled(e.target.checked)}
                />
                <span style={{ fontSize: 13, color: 'var(--text-muted)' }}>
                  {creating ? 'Create disabled (enable after reviewing)' : 'Enable this job'}
                </span>
              </label>
            </Row>

            <Row label="One-shot" htmlFor="cron-oneshot" hint="Auto-disable after the first run">
              <label style={{ display: 'flex', alignItems: 'center', gap: 8, cursor: 'pointer' }}>
                <input
                  id="cron-oneshot"
                  type="checkbox"
                  checked={oneShot}
                  onChange={(e) => setOneShot(e.target.checked)}
                />
                <span style={{ fontSize: 13, color: 'var(--text-muted)' }}>
                  Run once, then disable
                </span>
              </label>
            </Row>

            {/* Detail info for the selected job */}
            {detail && !creating && (
              <div style={{
                padding: 12,
                backgroundColor: 'var(--bg-sunken)',
                borderRadius: 'var(--radius-sm)',
                fontSize: 12,
                color: 'var(--text-muted)',
              }}>
                <div><strong>ID:</strong> {detail.id}</div>
                <div><strong>Next fire:</strong> {detail.next_fire ?? '—'}</div>
                <div><strong>Last fire:</strong> {detail.last_fire ?? '—'}</div>
                <div><strong>Run count:</strong> {detail.run_count}</div>
                {detail.consecutive_failures > 0 && (
                  <div style={{ color: 'var(--needs-input)' }}>
                    <strong>Consecutive failures:</strong> {detail.consecutive_failures}
                  </div>
                )}
              </div>
            )}

            {/* Action buttons */}
            <div style={{ display: 'flex', gap: 8, alignItems: 'center' }}>
              <button
                type="button"
                className="btn btn-primary px-3 py-2 rounded-lg text-sm font-medium"
                onClick={handleSubmit}
                disabled={submitting || !name || !schedule || !prompt}
                aria-label={creating ? 'Create cron job' : 'Save cron job'}
              >
                {submitting ? 'Saving…' : creating ? 'Create' : 'Save'}
              </button>

              {!creating && editing && (
                <button
                  type="button"
                  className="btn btn-ghost px-3 py-2 rounded-lg text-sm font-medium"
                  onClick={() => handleToggleEnabled(jobs.find((j) => j.id === editing)!)}
                >
                  {enabled ? 'Disable' : 'Enable'}
                </button>
              )}

              {!creating && editing && (
                confirmingDelete === editing ? (
                  <>
                    <span style={{ fontSize: 12, color: 'var(--text-muted)' }}>Confirm?</span>
                    <button
                      type="button"
                      className="btn btn-danger-ghost px-3 py-2 rounded-lg text-sm font-medium"
                      onClick={() => handleDelete(editing)}
                    >
                      Yes, delete
                    </button>
                    <button
                      type="button"
                      className="btn btn-ghost px-3 py-2 rounded-lg text-sm font-medium"
                      onClick={() => setConfirmingDelete(null)}
                    >
                      Cancel
                    </button>
                  </>
                ) : (
                  <button
                    type="button"
                    className="btn btn-danger-ghost px-3 py-2 rounded-lg text-sm font-medium"
                    onClick={() => setConfirmingDelete(editing)}
                  >
                    Delete
                  </button>
                )
              )}

              <button
                type="button"
                className="btn btn-ghost px-3 py-2 rounded-lg text-sm font-medium"
                onClick={() => { setEditing(null); setCreating(false); setFormError(null) }}
              >
                Cancel
              </button>
            </div>
          </div>
        )}
      </div>
    </div>
  )
}
