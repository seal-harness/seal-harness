import { describe, it, expect } from 'vitest'
import {
  readinessLabel,
  readinessHint,
  readinessTone,
  type ProviderReadiness,
} from '../readiness'

const ALL_STATES: ProviderReadiness[] = [
  'pending',
  'unknown',
  'not-installed',
  'not-running',
  'no-models',
  'no-fitting-model',
  'ready',
  'cloud',
]

describe('readinessLabel (test 40)', () => {
  it('renders nothing for pending (it is never shown, not "Unknown")', () => {
    expect(readinessLabel('pending')).toBe('')
  })

  it('covers all eight states', () => {
    expect(readinessLabel('unknown')).toBe('Status Unknown')
    expect(readinessLabel('not-installed')).toBe('Ollama Not Found')
    expect(readinessLabel('not-running')).toBe('Not Running')
    expect(readinessLabel('no-models')).toBe('No Models Pulled')
    expect(readinessLabel('no-fitting-model')).toBe('May Not Fit in RAM')
    expect(readinessLabel('ready', 1)).toBe('Ready · 1 Model')
    expect(readinessLabel('cloud')).toBe('Cloud')
  })

  it('singularises exactly one model', () => {
    expect(readinessLabel('ready', 1)).toBe('Ready · 1 Model')
  })

  it('pluralises every other count, including zero', () => {
    expect(readinessLabel('ready', 0)).toBe('Ready · 0 Models')
    expect(readinessLabel('ready', 2)).toBe('Ready · 2 Models')
    expect(readinessLabel('ready', 3)).toBe('Ready · 3 Models')
  })

  it('renders bare Ready when no count is present (an older cached payload)', () => {
    expect(readinessLabel('ready')).toBe('Ready')
    expect(readinessLabel('ready', undefined)).toBe('Ready')
  })

  it('is total: no state returns undefined', () => {
    for (const s of ALL_STATES) {
      expect(typeof readinessLabel(s)).toBe('string')
    }
  })
})

describe('readinessHint', () => {
  it('names the remedy for each actionable state', () => {
    expect(readinessHint('not-running')).toContain('ollama serve')
    expect(readinessHint('not-installed')).toContain('ollama.com')
    expect(readinessHint('no-fitting-model')).toContain('smaller')
  })

  it('uses the provider default model in the pull hint', () => {
    expect(readinessHint('no-models', 'qwen3:8b')).toContain('ollama pull qwen3:8b')
  })

  it('falls back to llama3.2 when no default model is known', () => {
    expect(readinessHint('no-models')).toContain('ollama pull llama3.2')
  })

  it('returns null for states that need no hint', () => {
    expect(readinessHint('pending')).toBeNull()
    expect(readinessHint('unknown')).toBeNull()
    expect(readinessHint('ready')).toBeNull()
    expect(readinessHint('cloud')).toBeNull()
  })

  it('is total: every state returns a string or null', () => {
    for (const s of ALL_STATES) {
      const h = readinessHint(s)
      expect(h === null || typeof h === 'string').toBe(true)
    }
  })
})

describe('readinessTone (test 39)', () => {
  it('is faint for pending and cloud', () => {
    expect(readinessTone('pending')).toBe('faint')
    expect(readinessTone('cloud')).toBe('faint')
  })

  it('is warn for the three "not usable" states', () => {
    expect(readinessTone('not-installed')).toBe('warn')
    expect(readinessTone('not-running')).toBe('warn')
    expect(readinessTone('no-models')).toBe('warn')
  })

  it('is muted for the advisory state and ok for ready', () => {
    // muted, not warn: D5.4 makes no-fitting-model advisory, and a warn tone
    // would turn a possibility into a verdict.
    expect(readinessTone('no-fitting-model')).toBe('muted')
    expect(readinessTone('ready')).toBe('ok')
  })

  it('is total: every state has a tone', () => {
    for (const s of ALL_STATES) {
      expect(['faint', 'muted', 'warn', 'ok']).toContain(readinessTone(s))
    }
  })
})
