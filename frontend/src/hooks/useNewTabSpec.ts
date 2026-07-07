import { useState, useEffect, useCallback } from 'react'
import { useAgents, useConfiguredProviders, fetchProviderModels, useDiscoverableWindows, type CreateTabBody } from './useApi'
import type { AgentInfo, DiscoverableWindow, ProviderInfo } from '../types'

export type NewTabKind = 'provider' | 'harness' | 'attach'

/** The harness flavours Seal knows how to spawn. Mirrors the backend's
 *  `HarnessFlavour` (known tools + a smart-constructed custom that rejects
 *  path separators). */
export type HarnessFlavour = 'claude-code' | 'codex' | 'opencode' | 'hermes' | 'custom'

export const CUSTOM_MODEL_VALUE = '__custom__'

/** State + handlers + computed values for the "new tab" inline composer.
 *
 * Rebuilt against Seal's flat `/api/tabs/new` body (T10's `CreateTabBody`:
 * `{kind, provider?, model?, agent?, branch_from?, harness_id?}`). The hook
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
  modelsLoading: boolean
  useCustomModel: boolean
  handleModelSelectChange: (v: string) => void

  agent: string
  agents: AgentInfo[]
  handleAgentChange: (v: string) => void

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

  // Computed
  validationError: string | null
  /** Build the flat POST /api/tabs/new body (T10's CreateTabBody shape). */
  buildBody: () => CreateTabBody
}

export function useNewTabSpec(): NewTabSpec {
  // Kind
  const [kind, setKind] = useState<NewTabKind>('provider')

  // Provider
  const { providers: configuredProviders, loaded: providersLoaded } = useConfiguredProviders()
  const [provider, setProvider] = useState<string>('')
  const [model, setModel] = useState<string>('')
  const [useCustomModel, setUseCustomModel] = useState(false)
  const [models, setModels] = useState<{ name: string; contextWindow: number }[]>([])
  const [modelsLoading, setModelsLoading] = useState(false)

  // Agent
  const { agents } = useAgents()
  const [agent, setAgent] = useState<string>('')
  const [agentTouched, setAgentTouched] = useState(false)

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

  // Default the provider to whatever Seal is configured to use (the entry
  // marked isDefault by the backend), or — failing that — the first one.
  useEffect(() => {
    if (!providersLoaded || configuredProviders.length === 0) return
    const names = configuredProviders.map((p) => p.name)
    if (!provider || !names.includes(provider)) {
      const def = configuredProviders.find((p) => p.isDefault)
      setProvider((def ?? configuredProviders[0]!).name)
    }
  }, [providersLoaded, configuredProviders, provider])

  // Fetch the model list when the provider changes (and we're in provider
  // mode). Pre-select the configured default if it appears in the list,
  // otherwise fall back to the first entry.
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
      setUseCustomModel(false)
      const dflt = info?.defaultModel
      const names = rows.map((r) => r.name)
      if (dflt && names.includes(dflt)) {
        setModel(dflt)
      } else {
        setModel(names.length > 0 ? names[0]! : '')
      }
    })
    return () => { cancelled = true }
  }, [kind, provider, configuredProviders])

  // Auto-select the configured default agent.
  useEffect(() => {
    if (agentTouched) return
    const def = Array.isArray(agents) ? agents.find((a) => a.isDefault) : undefined
    if (def) setAgent(def.name)
  }, [agents, agentTouched])

  const handleModelSelectChange = useCallback((value: string) => {
    if (value === CUSTOM_MODEL_VALUE) {
      setUseCustomModel(true)
      setModel('')
    } else {
      setUseCustomModel(false)
      setModel(value)
    }
  }, [])

  const handleAgentChange = useCallback((value: string) => {
    setAgentTouched(true)
    setAgent(value)
  }, [])

  // Validation. Defaults are designed to keep this null.
  const validationError: string | null = (() => {
    if (kind === 'provider') {
      if (providersLoaded && configuredProviders.length === 0) {
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

  const buildBody = useCallback((): CreateTabBody => {
    if (kind === 'provider') {
      const body: CreateTabBody = { kind: 'provider', provider, model: model.trim() }
      if (agent.trim()) body.agent = agent.trim()
      return body
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
  }, [kind, provider, model, agent, flavour, customBinary, attachSession])

  return {
    kind, setKind,
    configuredProviders, providersLoaded,
    provider, setProvider,
    model, setModel, models, modelsLoading, useCustomModel, handleModelSelectChange,
    agent, agents, handleAgentChange,
    flavour, setFlavour,
    customBinary, setCustomBinary,
    attachSession, setAttachSession,
    attachWindow, setAttachWindow,
    attachWindowIndex, setAttachWindowIndex,
    attachManual, setAttachManual,
    discoverableWindows, discoveryError, scanDiscoverable,
    validationError,
    buildBody,
  }
}