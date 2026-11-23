/**
 * Ollama readiness — the label, hint and tone tables (design §D4).
 *
 * One table per surface, parameterised. The backend sends the state enum plus
 * an optional usable count and nothing else: no free text, no RAM bytes, no
 * model names. That keeps the wire small and keeps every fit calculation
 * server-side.
 *
 * All three functions are **total** over the eight states. `pending` is the
 * interesting one: it is the state before this process has finished a probe, so
 * it must render as *nothing* rather than as a verdict. It is never shown, but
 * the signature must not have a hole.
 */

/** The eight wire values, kebab-case to match `api-key` / `vault-locked`. */
export type ProviderReadiness =
  | 'pending'
  | 'unknown'
  | 'not-installed'
  | 'not-running'
  | 'no-models'
  | 'no-fitting-model'
  | 'ready'
  | 'cloud'

export type ReadinessTone = 'faint' | 'muted' | 'warn' | 'ok'

/**
 * The pill text. Title Case throughout, matching "API Key" / "Not Configured" /
 * "Vault Locked".
 *
 * `ready` with no count renders `Ready` — a caller with an older cached payload
 * has no count to show, and an undefined result there would be a hole.
 */
export function readinessLabel(state: ProviderReadiness, usableModels?: number): string {
  switch (state) {
    case 'pending':
      return ''
    case 'unknown':
      return 'Status Unknown'
    case 'not-installed':
      return 'Ollama Not Found'
    case 'not-running':
      return 'Not Running'
    case 'no-models':
      return 'No Models Pulled'
    case 'no-fitting-model':
      return 'May Not Fit in RAM'
    case 'ready':
      if (usableModels === undefined) return 'Ready'
      return usableModels === 1 ? 'Ready · 1 Model' : `Ready · ${usableModels} Models`
    case 'cloud':
      return 'Cloud'
  }
}

/**
 * The hint under the pill, or `null` for states that need none.
 *
 * Why `May Not Fit in RAM` has a *hint* and not a verdict: the evidence
 * (`size × 1.25` vs total RAM) supports a possibility. A 24 GB-VRAM / 16 GB-RAM
 * host runs a 20 GB model fine, so the copy is a suggestion, never a claim.
 */
export function readinessHint(state: ProviderReadiness, defaultModel?: string): string | null {
  switch (state) {
    case 'not-installed':
      return 'Install Ollama from ollama.com, or check that it is on this PATH (a Docker-hosted daemon on another machine reports this too).'
    case 'not-running':
      return 'Start it with `ollama serve`.'
    case 'no-models':
      return `Pull a model with \`ollama pull ${defaultModel || 'llama3.2'}\`.`
    case 'no-fitting-model':
      return 'A smaller or quantized model may run better.'
    case 'pending':
    case 'unknown':
    case 'ready':
    case 'cloud':
      return null
  }
}

/** The visual weight. `faint` for the two states that are not really news. */
export function readinessTone(state: ProviderReadiness): ReadinessTone {
  switch (state) {
    case 'pending':
    case 'cloud':
      return 'faint'
    case 'no-fitting-model':
      return 'muted'
    case 'unknown':
      return 'faint'
    case 'not-installed':
    case 'not-running':
    case 'no-models':
      return 'warn'
    case 'ready':
      return 'ok'
  }
}

/**
 * Is this the one readiness state that positively means "there is nothing here
 * to use"?
 *
 * Only `not-installed` qualifies. It is the state the backend derives after
 * finding no daemon answering *and* no `ollama` binary on PATH — nothing the
 * operator can reach from this form. It is the only state that keeps a
 * provider out of a picker.
 *
 * Everything else stays listed, because everything else is one command away or
 * genuinely unknown:
 *
 * - `not-running` — installed; `ollama serve` fixes it.
 * - `no-models` — installed; `ollama pull <model>` fixes it.
 * - `no-fitting-model` — advisory only (design D5.4).
 * - `unknown` / `pending` — we have not observed anything. Absence of evidence
 *   must never become a claim, so these are never hidden.
 * - `ready` / `cloud` — usable.
 *
 * `undefined` (a non-Ollama provider, or an older payload) is likewise not
 * installed-absent: it is "not applicable", so it stays.
 */
export function isNotInstalled(readiness: ProviderReadiness | undefined): boolean {
  return readiness === 'not-installed'
}

/**
 * Is this provider one a picker may offer, or the form auto-select?
 *
 * The single definition of "offerable", shared by the dropdown filter
 * (`ProviderSelect`) and the new-tab form's auto-selection, so the two cannot
 * disagree: a value the dropdown hides is exactly a value the form must not
 * choose on the operator's behalf.
 *
 * `configured` absent means configured (back-compat with older payloads).
 * Absence is then the second, observed axis — see `isNotInstalled`.
 */
export function isOfferableProvider(p: {
  configured?: boolean
  readiness?: ProviderReadiness
}): boolean {
  if (p.configured === false) return false
  return !isNotInstalled(p.readiness)
}
