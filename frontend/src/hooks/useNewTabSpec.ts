import { useState, useEffect, useCallback, useMemo, useRef } from 'react'
import { useConfiguredProviders, fetchProviderModels, useDiscoverableWindows, useRepos, useMachines, type CreateTabBody, type MachinesResponse, fetchUiState, putUiState, addCustomModel, addRepo, type LastOptions } from './useApi'
import type { DiscoverableWindow, ProviderInfo } from '../types'

export type NewTabKind = 'provider' | 'harness' | 'attach'

/** The harness flavours Seal knows how to spawn. Mirrors the backend's
 *  `HarnessFlavour` (known tools + a smart-constructed custom that rejects
 *  path separators). */
export type HarnessFlavour = 'claude-code' | 'codex' | 'opencode' | 'hermes' | 'custom'

export const CUSTOM_MODEL_VALUE = '__custom__'

/** State + handlers + computed values for the "new tab" inline composer.
 *
 * Rebuilt against Seal's flat `/api/tabs/new` body (T10's `CreateTabBody`:
 * `{kind, provider?, model?, branch_from?, harness_id?}`). The hook
 * keeps the form in a continuously-valid state so the bottom message input
 * stays active; the only way to land in an invalid state is to opt into one
 * explicitly (pick "Custom…" model and don't fill it; pick the custom
 * harness flavour and don't name a binary). In those cases
 * `validationError` is non-null and the chat input disables. */
export interface NewTabSpec {
  // Kind
  kind: NewTabKind
  setKind: (k: NewTabKind) => void

  // Provider
  configuredProviders: ProviderInfo[]
  providersLoaded: boolean
  provider: string
  setProvider: (v: string) => void
  model: string
  setModel: (v: string) => void
  models: { name: string; contextWindow: number }[]
  /** Suggestions for the model combobox: the provider's configured frequent
   *  models, falling back to the statically-known model list when none are
   *  configured. Free-form entry is always allowed. */
  modelOptions: string[]
  modelsLoading: boolean
  useCustomModel: boolean
  handleModelSelectChange: (v: string) => void

  /** Custom model ids the user has typed before, most-recent first, deduped.
   *  Loaded from the persisted UI state on mount; the combobox offers these
   *  as suggestions. Populated by `recordCustomModel` on submit. */
  customModels: string[]

  // Repository ("set up repo" combo box)
  /** The current repo URL in the form. Empty string = no repo. */
  repo: string
  setRepo: (v: string) => void
  /** Repo URLs offered as "Set up repo" combobox suggestions: registered
   *  repo URLs (from /api/repos — the Repos tab) first, then the persisted
   *  history (previously-used URLs), deduped. */
  repoOptions: string[]
  /** Force a re-fetch of the registered repos (e.g. after the Repos tab
   *  adds/removes a repo). */
  refreshRepos: () => void
  /** The branch or tag to check out when `repo` is cloned. Empty string =
   *  no branch (the remote's default branch). Deliberately NOT persisted:
   *  a branch is repo-specific, so recalling the last one would be
   *  misleading. */
  repoBranch: string
  setRepoBranch: (v: string) => void

  // Harness
  flavour: HarnessFlavour
  setFlavour: (v: HarnessFlavour) => void
  customBinary: string
  setCustomBinary: (v: string) => void

  // Attach (Existing Harness) — adopt a running external tmux window.
  attachSession: string
  setAttachSession: (v: string) => void
  attachWindow: string
  setAttachWindow: (v: string) => void
  attachWindowIndex: number | null
  setAttachWindowIndex: (v: number | null) => void
  attachManual: boolean
  setAttachManual: (v: boolean) => void
  discoverableWindows: DiscoverableWindow[]
  discoveryError: boolean
  scanDiscoverable: () => Promise<void>

  // Execution machine (WU-7b). The picker renders only when the inventory
  // has >= 2 rows, and it is read-only in branch mode (the backend copies the
  // parent's pin).
  machineChoice: string
  setMachineChoice: (v: string) => void
  /** The inventory, or null while unloaded. `resolvable: false` disables
   *  Start; a non-null `error` with `resolvable: true` is the persistent
   *  malformed-file condition the Machines screen surfaces. */
  machines: MachinesResponse | null
  /** Whether to render the picker at all: >= 2 machines AND not branch mode. */
  showMachinePicker: boolean

  // Computed
  validationError: string | null
  /** Build the flat POST /api/tabs/new body (T10's CreateTabBody shape). */
  buildBody: () => CreateTabBody
  /** Persist the current form selection as the last-chosen options so the
   *  next "new tab" opens with the same values. Also records the custom
   *  model (if any) to the history. Best-effort; failures are swallowed. */
  persistOnSubmit: () => void
}

export function useNewTabSpec(
  /** Branch mode — a LIVE flag, not a mount-time option. A branched session
   *  must start with an EMPTY workdir, so a branch submit must never record
   *  the repo; otherwise the next ordinary "new tab" would restore it and
   *  auto-clone into an unrelated session (NewTabComposer dispatches
   *  SETUP_REPO for any non-empty repo).
   *
   *  This is read through a ref because the hook instance is created once at
   *  App mount and shared by every composer opening: a mount-time argument
   *  could never change when the user clicks "branch from here". */
  opts?: { branchModeRef?: { readonly current: boolean } },
): NewTabSpec {
  const branchModeRef = opts?.branchModeRef
  const inBranchMode = (): boolean => branchModeRef?.current === true
  // Kind
  const [kind, setKind] = useState<NewTabKind>('provider')

  // Provider
  const { providers: configuredProviders, loaded: providersLoaded } = useConfiguredProviders()
  const [provider, setProvider] = useState<string>('')
  const [model, setModel] = useState<string>('')
  // The machine picker's selection. '' is the SENTINEL — "Default (<name>)" —
  // whose value is omitted from the body. Without the sentinel the select
  // would render preselected and every web session would record a pin,
  // making the usage metric false on exactly its own population.
  const [machineChoice, setMachineChoice] = useState<string>('')
  const { data: machines } = useMachines()
  const [useCustomModel, setUseCustomModel] = useState(false)
  const [models, setModels] = useState<{ name: string; contextWindow: number }[]>([])
  const [modelsLoading, setModelsLoading] = useState(false)

  // Custom-model history (loaded from persisted UI state). The combobox
  // offers these as suggestions; `recordCustomModel` appends on submit.
  const [customModels, setCustomModels] = useState<string[]>([])
  // Repo URL history (loaded from persisted UI state). The "set up repo"
  // combobox offers these as suggestions; `recordRepo` appends on submit.
  const [repo, setRepo] = useState<string>('')
  // Optional branch/tag to check out when `repo` is cloned. Kept in memory
  // only — see the NewTabSpec doc (a branch is repo-specific, so persisting
  // the last one across "new tab" forms would be misleading).
  const [repoBranch, setRepoBranch] = useState<string>('')
  const [repoHistory, setRepoHistory] = useState<string[]>([])
  // Registered repos from /api/repos — their URLs are offered as "Set up
  // repo" suggestions alongside the persisted history. The hook re-fetches
  // on the `repos-changed` WS invalidation frame (same as the Repos tab).
  const { repos: registeredRepos, refresh: refreshRepos } = useRepos()
  // When lastOptions restores a provider+model, the model-fetch effect
  // would normally clobber the restored model with the provider's default.
  // `pendingRestoreModel` holds the restored model id so the fetch effect
  // prefers it over the default; it's cleared once consumed.
  const pendingRestoreModel = useRef<string | null>(null)

  // Harness
  const [flavour, setFlavour] = useState<HarnessFlavour>('claude-code')
  const [customBinary, setCustomBinary] = useState('')

  // Attach (Existing Harness)
  const [attachSession, setAttachSession] = useState('')
  const [attachWindow, setAttachWindow] = useState('')
  const [attachWindowIndex, setAttachWindowIndex] = useState<number | null>(null)
  const [attachManual, setAttachManual] = useState(false)
  const { windows: discoverableWindows, error: discoveryError, scan: scanDiscoverable } = useDiscoverableWindows()

  // Auto-load the detected-sessions dropdown the first time the user opens
  // the Existing-Harness section.
  const [attachScanned, setAttachScanned] = useState(false)
  useEffect(() => {
    if (kind !== 'attach') {
      if (attachScanned) setAttachScanned(false)
      return
    }
    if (attachScanned) return
    setAttachScanned(true)
    void scanDiscoverable()
  }, [kind, attachScanned, scanDiscoverable])

  // Load the persisted last-options + custom-model history on mount so the
  // form opens with the last-used selection. The provider+model restore is
  // staged via `pendingRestoreModel` so the model-fetch effect (which fires
  // when the provider effect lands) honors the restored id instead of the
  // provider's configured default. Runs once (the ref guards against
  // StrictMode double-invoke without cancelling an in-flight fetch).
  const restoredRef = useRef(false)
  useEffect(() => {
    if (restoredRef.current) return
    restoredRef.current = true
    void fetchUiState().then((st) => {
      if (!st) return
      const models = Array.isArray(st.custom_models) ? st.custom_models : []
      if (models.length > 0) setCustomModels(models)
      const repos = Array.isArray(st.repo_history) ? st.repo_history : []
      if (repos.length > 0) setRepoHistory(repos)
      const opts = st.last_options
      if (!opts) return
      setKind(opts.kind as NewTabKind)
      if (opts.flavour) setFlavour(opts.flavour as HarnessFlavour)
      if (opts.customBinary) setCustomBinary(opts.customBinary)
      if (opts.attachSession) setAttachSession(opts.attachSession)
      if (opts.attachWindow) setAttachWindow(opts.attachWindow)
      if (opts.attachManual) setAttachManual(true)
      // Branch mode: never restore a last-used repo. The branch's workdir
      // must start empty, and this box is what triggers SETUP_REPO.
      if (opts.repo && !inBranchMode()) setRepo(opts.repo)
      // Provider + model: stage the model so the model-fetch effect (which
      // fires when the restored provider lands) honors it instead of the
      // configured default. The fetch effect clears the ref once consumed.
      if (opts.provider) setProvider(opts.provider)
      if (opts.model) {
        pendingRestoreModel.current = opts.model
        if (opts.useCustomModel) setUseCustomModel(true)
      }
    })
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  // Default the provider to whatever Seal is configured to use (the entry
  // marked isDefault by the backend) — but only among the *configured*
  // providers. Falling back to the first configured one, then the first
  // overall (so an unconfigured provider is never auto-selected even when
  // it is the only entry). `configured` is absent => configured (back-compat).
  useEffect(() => {
    if (!providersLoaded || configuredProviders.length === 0) return
    const names = configuredProviders.map((p) => p.name)
    const isCfg = (n: string) =>
      configuredProviders.find((p) => p.name === n)?.configured !== false
    if (!provider || !names.includes(provider) || !isCfg(provider)) {
      const cfg = configuredProviders.filter((p) => p.configured !== false)
      const def = cfg.find((p) => p.isDefault)
      const fallback = (def ?? cfg[0] ?? configuredProviders[0])!.name
      setProvider(fallback)
    }
  }, [providersLoaded, configuredProviders, provider])

  // Fetch the model list when the provider changes (and we're in provider
  // mode). Pre-select the configured default if it appears in the list,
  // otherwise fall back to the first entry. When a `pendingRestoreModel`
  // is set (from the persisted last-options), prefer it over the default
  // and clear the pending ref once consumed.
  useEffect(() => {
    if (kind !== 'provider' || !provider) return
    let cancelled = false
    setModelsLoading(true)
    setModels([])
    const info = configuredProviders.find((p) => p.name === provider)
    fetchProviderModels(provider).then((rows) => {
      if (cancelled) return
      setModels(rows)
      setModelsLoading(false)
      const names = rows.map((r) => r.name)
      const restored = pendingRestoreModel.current
      pendingRestoreModel.current = null
      if (restored && names.includes(restored)) {
        setUseCustomModel(false)
        setModel(restored)
        return
      }
      // A restored model may be custom — the combobox accepts free entry, so
      // just keep the id and mark it custom when it is not a suggestion.
      const configured = info?.models ?? []
      const suggestions = configured.length > 0 ? configured : names
      if (restored) {
        setUseCustomModel(!suggestions.includes(restored))
        setModel(restored)
        return
      }
      const dflt = info?.defaultModel
      if (dflt) {
        setUseCustomModel(!suggestions.includes(dflt))
        setModel(dflt)
      } else {
        setUseCustomModel(false)
        setModel(suggestions.length > 0 ? suggestions[0]! : '')
      }
    })
    return () => { cancelled = true }
  }, [kind, provider, configuredProviders])

  const selectedProviderInfo = configuredProviders.find((p) => p.name === provider)
  const modelOptions = useMemo(() => {
    const configured = selectedProviderInfo?.models ?? []
    if (configured.length > 0) return configured
    return models.map((m) => m.name)
  }, [selectedProviderInfo, models])

  const handleModelSelectChange = useCallback((value: string) => {
    if (value === CUSTOM_MODEL_VALUE) {
      setUseCustomModel(true)
      setModel('')
    } else {
      setUseCustomModel(false)
      setModel(value)
    }
  }, [])

  // Validation. Defaults are designed to keep this null.
  const validationError: string | null = (() => {
    if (kind === 'provider') {
      if (providersLoaded && !configuredProviders.some((p) => p.configured !== false)) {
        return 'No providers configured — set an API key or start Ollama'
      }
      if (modelsLoading) return 'Loading models…'
      if (!model.trim()) return useCustomModel ? 'Enter a custom model id' : 'Pick a model'
    }
    if (kind === 'harness' && flavour === 'custom' && !customBinary.trim()) {
      return 'Binary name is required for custom flavour'
    }
    if (kind === 'attach') {
      if (!attachSession.trim()) return 'Pick or enter a session to attach to'
      return null
    }
    return null
  })()

  // The >= 2 rule, one predicate: an ssh-only count would fire while the
  // picker was already rendered, because `local` counts toward the total.
  const showMachinePicker = (machines?.machines?.length ?? 0) >= 2 && !inBranchMode()

  const buildBody = useCallback((): CreateTabBody => {
    // One rule for both omissions: the picker sends nothing when it is not
    // rendered, and nothing when the user left it on the sentinel.
    const machineField =
      !inBranchMode() && machineChoice !== '' ? { machine: machineChoice } : {}
    if (kind === 'provider') {
      return { kind: 'provider', provider, model: model.trim(), ...machineField }
    }
    if (kind === 'harness') {
      // Seal's T10 takes a flat `kind: 'harness'` + harness_id. The harness
      // flavour + custom binary are encoded into the harness_id field as
      // `flavour:<name>` (the gateway decodes the prefix); a custom binary
      // is sent as `custom:<binary>`. Phase 4 will widen the body when the
      // harness spawn flow is fleshed out.
      const effectiveFlavour = flavour === 'custom' ? `custom:${customBinary.trim()}` : flavour
      return { kind: 'harness', harness_id: effectiveFlavour }
    }
    // kind === 'attach' — adoption bypasses buildBody (the caller invokes
    // adoptWindow directly with the session/window/windowIndex). Return a
    // sentinel the caller will not send.
    return { kind: 'attach', harness_id: attachSession }
  }, [kind, provider, model, flavour, customBinary, attachSession, machineChoice])

  // Persist the current form selection + record the custom model (if any).
  // Best-effort; failures are swallowed (the UI still works within the
  // session, just without cross-restart recall). Fires after a successful
  // submit so the next "new tab" opens with the same values.
  const persistOnSubmit = useCallback(() => {
    const trimmedModel = model.trim()
    const isCustomModel = trimmedModel !== '' && !modelOptions.includes(trimmedModel)
    const opts: LastOptions = {
      kind,
      provider,
      model: trimmedModel,
      useCustomModel: isCustomModel,
      flavour,
      customBinary: customBinary.trim(),
      attachSession,
      attachWindow,
      attachManual,
      // Branch mode must not rewrite the remembered repo, or the parent's
      // URL would leak into the next ordinary new-tab form.
      repo: inBranchMode() ? '' : repo.trim(),
    }
    void putUiState(opts)
    if (isCustomModel) {
      void addCustomModel(trimmedModel)
      setCustomModels((prev) => {
        const next = [trimmedModel, ...prev.filter((m) => m !== trimmedModel)]
        return next.slice(0, 32)
      })
    }
    if (repo.trim()) {
      void addRepo(repo.trim())
      setRepoHistory((prev) => {
        const next = [repo.trim(), ...prev.filter((r) => r !== repo.trim())]
        return next.slice(0, 32)
      })
    }
  }, [kind, provider, model, modelOptions, flavour, customBinary, attachSession, attachWindow, attachManual, repo])

  return {
    kind, setKind,
    configuredProviders, providersLoaded,
    provider, setProvider,
    model, setModel, models, modelOptions, modelsLoading, useCustomModel, handleModelSelectChange,
    customModels,
    repo, setRepo,
    repoBranch, setRepoBranch,
    // Merge registered repo URLs with persisted history (deduped,
    // registered repos first so they're at the top of the dropdown).
    repoOptions: [
      ...registeredRepos.map((r) => r.url),
      ...repoHistory.filter((u) => !registeredRepos.some((r) => r.url === u)),
    ],
    refreshRepos,
    flavour, setFlavour,
    customBinary, setCustomBinary,
    attachSession, setAttachSession,
    attachWindow, setAttachWindow,
    attachWindowIndex, setAttachWindowIndex,
    attachManual, setAttachManual,
    discoverableWindows, discoveryError, scanDiscoverable,
    validationError,
    machineChoice,
    setMachineChoice,
    machines,
    showMachinePicker,
    buildBody,
    persistOnSubmit,
  }
}
