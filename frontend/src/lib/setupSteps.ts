/**
 * The first-run wizard's step registry and wire parser.
 *
 * Two rules shape this file:
 *
 * 1. **The server is authoritative.** `GET /api/setup` decides each step's
 *    status; the client renders it. A step the server reports but this build
 *    has never heard of still gets a card (generic, from the id) — never a
 *    silent block, and never a skipped requirement.
 * 2. **Adding a step is one registry entry + one component.** Chat channels
 *    will land this way: a `required: false` row appended here, a component
 *    registered in the wizard's step switch. Nothing else in the gate changes.
 */

export type SetupStatus = 'ready' | 'pending' | 'blocked'

export interface SetupStep {
  id: string
  required: boolean
  status: SetupStatus
  detail: string | null
  actions: string[]
}

export interface ProviderCard {
  id: string
  label: string
  configured: boolean
  isDefault: boolean
  default_model: string | null
  /** True when the provider has no built-in endpoint (the generic
   *  OpenAI-compatible option), so the wizard must collect a base URL. */
  requires_base_url: boolean
}

export interface SetupState {
  required_complete: boolean
  steps: SetupStep[]
  providers: ProviderCard[]
}

/** A parsed state plus the statuses this build did not recognise. An unknown
 *  status is treated as `pending` (fail closed: it can never make a required
 *  step look done) and surfaced so a stale UI is diagnosable instead of
 *  mysterious. */
export interface ParsedSetupState extends SetupState {
  unknownStatuses: string[]
}

const KNOWN_STATUSES: SetupStatus[] = ['ready', 'pending', 'blocked']

/** Actions that get a button in the wizard's action bar. Anything else —
 *  `create` (the vault step's backend cards are the action, and a second
 *  "Create vault" button next to them is a puzzle, not a choice), the
 *  provider step's `configure`, or a verb from a newer server — renders no
 *  button, because the step's own body owns that interaction. */
const BAR_ACTIONS: Record<string, string> = {
  resume: 'Finish creating the vault',
  reopen: 'Reopen the vault',
  recheck: 'Re-check',
}

export function actionLabel(verb: string): string | null {
  return BAR_ACTIONS[verb] ?? null
}

export function barActions(step: SetupStep): string[] {
  return step.actions.filter((verb) => actionLabel(verb) !== null)
}

export interface SetupStepDef {
  id: string
  title: string
  blurb: string
}

/** The wizard's order. `vault` then `provider`, and a future optional step
 *  (chat channels) appends here as `required: false`. */
export const setupStepRegistry: SetupStepDef[] = [
  {
    id: 'vault',
    title: 'Create your vault',
    blurb: 'Seal keeps API keys and tokens in an encrypted vault.',
  },
  {
    id: 'provider',
    title: 'Choose an LLM provider',
    blurb: 'Sessions need a provider and a model to talk to.',
  },
]

export interface RailEntry extends SetupStepDef {
  step: SetupStep
  /** False when the server reported a step this build has no card for. */
  registered: boolean
}

/** The left rail: registry order first, then any server-only steps, so an
 *  unregistered required step is visible (and blocking) rather than invisible. */
export function resolveRail(state: SetupState): RailEntry[] {
  const byId = new Map(state.steps.map((step) => [step.id, step]))
  const rail: RailEntry[] = []
  for (const def of setupStepRegistry) {
    const step = byId.get(def.id)
    if (step) {
      rail.push({ ...def, step, registered: true })
      byId.delete(def.id)
    }
  }
  for (const step of state.steps) {
    if (byId.has(step.id)) {
      rail.push({
        id: step.id,
        title: genericTitle(step.id),
        blurb: step.detail ?? '',
        step,
        registered: false,
      })
    }
  }
  return rail
}

function genericTitle(id: string): string {
  const words = id.replace(/[_-]+/g, ' ').trim()
  if (words.length === 0) return 'Setup step'
  return words.charAt(0).toUpperCase() + words.slice(1)
}

/** The first step that still needs the operator, in rail order. `null` means
 *  the wizard is done. Blocked steps count: they need an action too. */
export function firstIncompleteStepIndex(state: SetupState): number | null {
  const index = state.steps.findIndex((step) => step.status !== 'ready')
  return index === -1 ? null : index
}

/** Parse `GET /api/setup`. `null` means "this is not a setup payload" and the
 *  gate fails closed rather than guessing. */
export function parseSetupState(value: unknown): ParsedSetupState | null {
  if (!isRecord(value)) return null
  const { required_complete, steps, providers } = value
  if (typeof required_complete !== 'boolean') return null
  if (!Array.isArray(steps) || !Array.isArray(providers)) return null
  const parsedSteps: SetupStep[] = []
  const unknownStatuses: string[] = []
  for (const raw of steps) {
    const step = parseStep(raw)
    if (step === null) return null
    if (step.unknownStatus !== undefined) unknownStatuses.push(step.unknownStatus)
    parsedSteps.push(step.step)
  }
  const parsedProviders: ProviderCard[] = []
  for (const raw of providers) {
    const card = parseProvider(raw)
    if (card === null) return null
    parsedProviders.push(card)
  }
  return {
    required_complete,
    steps: parsedSteps,
    providers: parsedProviders,
    unknownStatuses,
  }
}

function parseStep(raw: unknown): { step: SetupStep; unknownStatus?: string } | null {
  if (!isRecord(raw)) return null
  const { id, required, status, detail, actions } = raw
  if (typeof id !== 'string' || id.length === 0) return null
  if (typeof required !== 'boolean') return null
  if (typeof status !== 'string') return null
  const parsedStatus = KNOWN_STATUSES.includes(status as SetupStatus)
    ? (status as SetupStatus)
    : 'pending'
  const step: SetupStep = {
    id,
    required,
    status: parsedStatus,
    detail: typeof detail === 'string' ? detail : null,
    actions: Array.isArray(actions) ? actions.filter((a): a is string => typeof a === 'string') : [],
  }
  return KNOWN_STATUSES.includes(status as SetupStatus)
    ? { step }
    : { step, unknownStatus: status }
}

function parseProvider(raw: unknown): ProviderCard | null {
  if (!isRecord(raw)) return null
  const { id, label, configured, isDefault, default_model, requires_base_url } = raw
  if (typeof id !== 'string' || typeof label !== 'string') return null
  if (typeof configured !== 'boolean' || typeof isDefault !== 'boolean') return null
  return {
    id,
    label,
    configured,
    isDefault,
    default_model: typeof default_model === 'string' ? default_model : null,
    requires_base_url: requires_base_url === true,
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null
}
