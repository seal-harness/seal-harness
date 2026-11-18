/**
 * Human labels for provider ids — wizard-local on purpose.
 *
 * The four existing components render provider names through their own maps;
 * extracting a shared `providerLabel` and migrating them is a follow-up. The
 * one rule that matters here: an id this build does not know still renders as
 * itself, never as an empty string and never as an error.
 */

const LABELS: Record<string, string> = {
  anthropic: 'Anthropic',
  openrouter: 'OpenRouter',
  ollama: 'Ollama',
  'ollama-cloud': 'Ollama Cloud',
  openai: 'OpenAI',
  // The generic type. Its id no longer disambiguates it from real OpenAI, so
  // dropdowns use OPENAI_COMPATIBLE_OPTION below instead of this short label.
  'openai-compatible': 'OpenAI-compatible',
}

/** The dropdown option text for the generic type. Kept separate from the short
 *  label so the two strings cannot be confused for one another (design item
 *  39). */
export const OPENAI_COMPATIBLE_OPTION = 'OpenAI-compatible (custom / self-hosted)'

export function providerLabel(id: string): string {
  const known = LABELS[id.toLowerCase()]
  if (known !== undefined) return known
  const trimmed = id.trim()
  return trimmed.length > 0 ? trimmed : 'Unknown provider'
}
