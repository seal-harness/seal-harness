import type React from 'react'

/**
 * The provider configuration fields shared by the Providers CRUD editor and
 * the first-run setup wizard. Both forms write the same values into
 * @config.toml (via POST/PUT /api/providers), so the field set — including the
 * operator's frequently-used model list — lives here once.
 */

export interface ProviderFormValues {
  apiKey: string
  baseUrl: string
  defaultModel: string
  /** Raw textarea contents: one model id per line (commas also accepted).
   *  Parse with `modelsFromText` when submitting. Keeping the raw text means
   *  a trailing newline survives while the user is typing. */
  modelsText: string
}

export function emptyProviderFormValues(): ProviderFormValues {
  return { apiKey: '', baseUrl: '', defaultModel: '', modelsText: '' }
}

/** Build the form values from a provider detail (editing). The API key is
 *  write-only, so it always starts empty. */
export function providerFormValuesFrom(provider: {
  baseUrl?: string | null
  defaultModel?: string | null
  models?: string[] | null
}): ProviderFormValues {
  return {
    apiKey: '',
    baseUrl: provider.baseUrl ?? '',
    defaultModel: provider.defaultModel ?? '',
    modelsText: (provider.models ?? []).join('\n'),
  }
}

/** Parse the model textarea into the wire array: trim, drop blanks, dedupe. */
export function modelsFromText(text: string): string[] {
  const seen = new Set<string>()
  for (const raw of text.split(/[\n,]+/)) {
    const model = raw.trim()
    if (model) seen.add(model)
  }
  return Array.from(seen)
}

const labelStyle: React.CSSProperties = {
  fontSize: 12,
  fontWeight: 500,
  color: 'var(--text-muted)',
}

const inputStyle: React.CSSProperties = {
  display: 'block',
  width: '100%',
  fontSize: 14,
  padding: '6px 10px',
  backgroundColor: 'var(--bg-sunken)',
  border: '1px solid var(--border)',
  borderRadius: 'var(--radius-sm)',
  color: 'var(--text-primary)',
  outline: 'none',
  fontFamily: 'inherit',
}

const hintStyle: React.CSSProperties = {
  fontSize: 11,
  color: 'var(--text-faint)',
  marginTop: 4,
}

const errorStyle: React.CSSProperties = {
  fontSize: 11,
  color: 'var(--needs-input)',
  marginTop: 4,
}

type Layout = 'grid' | 'stacked'

function Field({
  label, htmlFor, hint, error, layout, children,
}: {
  label: string
  htmlFor: string
  hint?: string
  error?: string | null
  layout: Layout
  children: React.ReactNode
}) {
  if (layout === 'stacked') {
    return (
      <label style={{ ...labelStyle, display: 'block', marginTop: 14 }}>
        {label}
        <div style={{ marginTop: 4 }}>{children}</div>
        {error ? <span style={{ ...errorStyle, display: 'block' }}>{error}</span> : null}
        {hint ? <span style={{ ...hintStyle, display: 'block' }}>{hint}</span> : null}
      </label>
    )
  }
  return (
    <div style={{ display: 'grid', gridTemplateColumns: '140px 1fr', alignItems: 'start', gap: 12 }}>
      <label htmlFor={htmlFor} style={labelStyle}>{label}</label>
      <div>
        {children}
        {error ? <div style={errorStyle}>{error}</div> : null}
        {hint ? <div style={hintStyle}>{hint}</div> : null}
      </div>
    </div>
  )
}

export interface ProviderFormFieldsProps {
  idPrefix: string
  values: ProviderFormValues
  onChange: (patch: Partial<ProviderFormValues>) => void
  /** `grid` matches the Providers editor; `stacked` matches the setup wizard. */
  layout?: Layout
  creating?: boolean
  isKeyless?: boolean
  isVaultLocked?: boolean
  isOllama?: boolean
  isOpenAIType?: boolean
  baseUrlError?: string | null
  showApiKey?: boolean
  showBaseUrl?: boolean
  showDefaultModel?: boolean
  showModels?: boolean
}

export function ProviderFormFields({
  idPrefix,
  values,
  onChange,
  layout = 'grid',
  creating = false,
  isKeyless = false,
  isVaultLocked = false,
  isOllama = false,
  isOpenAIType = false,
  baseUrlError = null,
  showApiKey = true,
  showBaseUrl = true,
  showDefaultModel = true,
  showModels = true,
}: ProviderFormFieldsProps) {
  const apiKeyId = `${idPrefix}-api-key`
  const baseUrlId = `${idPrefix}-base-url`
  const defaultModelId = `${idPrefix}-default-model`
  const modelsId = `${idPrefix}-models`

  const apiKeyPlaceholder = isKeyless ? '(keyless — not required)' : 'Enter API key'
  const apiKeyHint = creating
    ? 'Stored in the vault — never persisted in cleartext. Leave blank for keyless providers (e.g. local Ollama).'
    : isKeyless
      ? 'This provider is keyless (local). No API key required.'
      : isVaultLocked
        ? 'Vault is locked — unlock it to manage API keys.'
        : 'Paste a new key to rotate (the stored key is never shown).'

  const baseUrlPlaceholder = isOllama
    ? 'http://localhost:11434'
    : isOpenAIType
      ? 'https://api.openai.com/v1'
      : '(optional)'
  const baseUrlHint = isOllama
    ? 'Ollama server URL. Leave blank for default (http://localhost:11434).'
    : isOpenAIType
      ? 'Required for OpenAI-compatible providers, e.g. https://api.openai.com/v1 or http://localhost:8000/v1.'
      : 'Custom API endpoint URL (optional).'

  return (
    <>
      {showApiKey ? (
        <Field
          label="API key"
          htmlFor={apiKeyId}
          hint={apiKeyHint}
          layout={layout}
        >
          <input
            id={apiKeyId}
            type="password"
            value={values.apiKey}
            onChange={(e) => onChange({ apiKey: e.target.value })}
            style={inputStyle}
            placeholder={apiKeyPlaceholder}
            autoComplete="off"
            disabled={isVaultLocked}
            data-testid="provider-api-key-input"
          />
        </Field>
      ) : null}

      {showBaseUrl ? (
        <Field
          label="Base URL"
          htmlFor={baseUrlId}
          hint={baseUrlHint}
          error={baseUrlError}
          layout={layout}
        >
          <input
            id={baseUrlId}
            type="text"
            value={values.baseUrl}
            onChange={(e) => onChange({ baseUrl: e.target.value })}
            style={inputStyle}
            placeholder={baseUrlPlaceholder}
            autoComplete="off"
            aria-invalid={baseUrlError !== null}
            data-testid="provider-base-url-input"
          />
        </Field>
      ) : null}

      {showDefaultModel ? (
        <Field
          label="Default model"
          htmlFor={defaultModelId}
          hint="Provider-specific model id. Leave blank to use the provider default."
          layout={layout}
        >
          <input
            id={defaultModelId}
            type="text"
            value={values.defaultModel}
            onChange={(e) => onChange({ defaultModel: e.target.value })}
            style={inputStyle}
            placeholder="e.g. claude-sonnet-4-20250514"
            autoComplete="off"
            data-testid="provider-default-model-input"
          />
        </Field>
      ) : null}

      {showModels ? (
        <Field
          label="Frequent models"
          htmlFor={modelsId}
          hint="One model id per line (or comma-separated). These appear as suggestions in the new-tab model picker."
          layout={layout}
        >
          <textarea
            id={modelsId}
            value={values.modelsText}
            onChange={(e) => onChange({ modelsText: e.target.value })}
            style={{ ...inputStyle, minHeight: 72, resize: 'vertical', lineHeight: 1.4 }}
            placeholder={'claude-opus-4-8\nclaude-sonnet-4'}
            autoComplete="off"
            spellCheck={false}
            data-testid="provider-models-input"
          />
        </Field>
      ) : null}
    </>
  )
}
