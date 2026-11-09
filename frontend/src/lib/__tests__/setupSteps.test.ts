import { describe, it, expect } from 'vitest'
import {
  barActions,
  firstIncompleteStepIndex,
  parseSetupState,
  resolveRail,
  setupStepRegistry,
  actionLabel,
  type ProviderCard,
  type SetupState,
  type SetupStep,
} from '../setupSteps'
import { providerLabel } from '../providerLabels'

const wireSteps: SetupStep[] = [
  {
    id: 'vault',
    required: true,
    status: 'pending',
    detail: 'Create an encrypted vault for API keys and tokens.',
    actions: ['create'],
  },
  {
    id: 'provider',
    required: true,
    status: 'pending',
    detail: 'Add an LLM provider.',
    actions: ['configure'],
  },
]

const wireProviders: ProviderCard[] = [
  {
    id: 'anthropic',
    label: 'Anthropic',
    configured: false,
    isDefault: false,
    default_model: null,
    requires_base_url: false,
  },
]

const wire = { required_complete: false, steps: wireSteps, providers: wireProviders }

function state(overrides: Partial<SetupState> = {}): SetupState {
  return {
    required_complete: false,
    steps: wireSteps.map((s) => ({ ...s })),
    providers: wireProviders.map((p) => ({ ...p })),
    ...overrides,
  }
}

describe('parseSetupState', () => {
  it('accepts the wire shape', () => {
    const parsed = parseSetupState(wire)
    expect(parsed).not.toBeNull()
    if (parsed === null) return
    expect(parsed.steps.map((s) => s.id)).toEqual(['vault', 'provider'])
    expect(parsed.steps[0]?.status).toBe('pending')
    expect(parsed.providers[0]?.label).toBe('Anthropic')
    // The server decides which providers need an endpoint; the wizard obeys.
    expect(parsed.providers[0]?.requires_base_url).toBe(false)
    expect(parsed.unknownStatuses).toEqual([])
  })

  it('treats an unknown status as pending and flags it', () => {
    const parsed = parseSetupState({
      ...wire,
      steps: [{ ...wireSteps[0], status: 'waiting-for-godot' }, wireSteps[1]],
    })
    expect(parsed).not.toBeNull()
    if (parsed === null) return
    // Fail closed: an unrecognised status can never make a required step ready.
    expect(parsed.steps[0]?.status).toBe('pending')
    expect(parsed.unknownStatuses).toEqual(['waiting-for-godot'])
  })

  it('rejects a malformed payload', () => {
    expect(parseSetupState(null)).toBeNull()
    expect(parseSetupState('nope')).toBeNull()
    expect(parseSetupState({ steps: [], providers: [] })).toBeNull()
    expect(parseSetupState({ ...wire, steps: [{ id: 'vault' }] })).toBeNull()
    expect(parseSetupState({ ...wire, providers: [{ id: 'x' }] })).toBeNull()
    // An absent `requires_base_url` is `false`, not a parse failure: the field
    // is additive on the wire.
    const legacy = parseSetupState({
      ...wire,
      providers: [{ id: 'anthropic', label: 'Anthropic', configured: false, isDefault: false, default_model: null }],
    })
    expect(legacy?.providers[0]?.requires_base_url).toBe(false)
  })
})

describe('firstIncompleteStepIndex', () => {
  it('returns null when everything is ready', () => {
    const ready = state({
      required_complete: true,
      steps: wireSteps.map((s) => ({ ...s, status: 'ready' as const })),
    })
    expect(firstIncompleteStepIndex(ready)).toBeNull()
  })

  it('returns the first pending step', () => {
    const partial = state({
      steps: [{ ...wireSteps[0], status: 'ready' } as SetupStep, wireSteps[1] as SetupStep],
    })
    expect(firstIncompleteStepIndex(partial)).toBe(1)
    expect(firstIncompleteStepIndex(state())).toBe(0)
  })
})

describe('resolveRail', () => {
  it('renders a generic card for an unregistered server step', () => {
    const extra: SetupStep = {
      id: 'chat_channels',
      required: false,
      status: 'pending',
      detail: 'Connect Telegram or Signal.',
      actions: ['configure'],
    }
    const rail = resolveRail(state({ steps: [...wireSteps, extra] }))
    expect(rail.map((entry) => entry.id)).toEqual(['vault', 'provider', 'chat_channels'])
    const last = rail[2]
    expect(last).toBeDefined()
    expect(last?.registered).toBe(false)
    expect(last?.title).toBe('Chat channels')
    expect(last?.step.required).toBe(false)
  })

  it('the registry order is vault then provider', () => {
    expect(setupStepRegistry.map((def) => def.id)).toEqual(['vault', 'provider'])
  })
})

describe('action bar', () => {
  it('unknown action verbs render no bar button', () => {
    expect(actionLabel('frobnicate')).toBeNull()
    const step: SetupStep = { ...wireSteps[0], actions: ['recheck', 'frobnicate', 'configure', 'create'] } as SetupStep
    expect(barActions(step)).toEqual(['recheck'])
  })
})

describe('providerLabels', () => {
  it('falls back to the raw id for an unknown provider', () => {
    expect(providerLabel('anthropic')).toBe('Anthropic')
    expect(providerLabel('mistral')).toBe('mistral')
    expect(providerLabel('')).toBe('Unknown provider')
  })
})
