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
  openai: 'OpenAI-compatible',
}

export function providerLabel(id: string): string {
  const known = LABELS[id.toLowerCase()]
  if (known !== undefined) return known
  const trimmed = id.trim()
  return trimmed.length > 0 ? trimmed : 'Unknown provider'
}
