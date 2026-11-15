import { describe, it, expect } from 'vitest'
import { agentOptionLabel, groupAgents, groupLabel } from '../agentGroups'
import type { AgentDefInfo } from '../../types'

function makeAgent(overrides: Partial<AgentDefInfo> = {}): AgentDefInfo {
  return {
    id: 'planner',
    name: 'planner',
    isDefault: false,
    displayName: 'Planner',
    provider: 'anthropic',
    model: 'claude-sonnet-4',
    system: null,
    tools: 'all',
    group: null,
    created_at: '2026-01-01T00:00:00Z',
    updated_at: '2026-01-01T00:00:00Z',
    session: 'web',
    ...overrides,
  }
}

describe('groupLabel', () => {
  it('falls back to "Agents" for null / empty / whitespace groups', () => {
    expect(groupLabel(null)).toBe('Agents')
    expect(groupLabel('')).toBe('Agents')
    expect(groupLabel('   ')).toBe('Agents')
  })

  it('uses the trimmed group name otherwise', () => {
    expect(groupLabel(' core ')).toBe('core')
  })
})

describe('groupAgents', () => {
  it('puts ungrouped agents first, then named groups alphabetically', () => {
    const groups = groupAgents([
      makeAgent({ id: 'sre', group: 'ops' }),
      makeAgent({ id: 'coder', group: null }),
      makeAgent({ id: 'pm', group: 'core' }),
    ])
    expect(groups.map((g) => g.label)).toEqual(['Agents', 'core', 'ops'])
    expect(groups[0]!.ungrouped).toBe(true)
    expect(groups[1]!.ungrouped).toBe(false)
  })

  it('orders agents within a group by id', () => {
    const groups = groupAgents([
      makeAgent({ id: 'zoe', group: 'core' }),
      makeAgent({ id: 'alice', group: 'core' }),
    ])
    expect(groups[0]!.agents.map((a) => a.id)).toEqual(['alice', 'zoe'])
  })

  it('returns no groups for an empty list', () => {
    expect(groupAgents([])).toEqual([])
  })
})

describe('agentOptionLabel', () => {
  it('uses the display name', () => {
    expect(agentOptionLabel(makeAgent({ id: 'p', displayName: 'Planner' }))).toBe('Planner')
  })

  it('falls back to the id when the display name is blank', () => {
    expect(agentOptionLabel(makeAgent({ id: 'p', displayName: '' }))).toBe('p')
    expect(agentOptionLabel(makeAgent({ id: 'p', displayName: '  ' }))).toBe('p')
  })

  it('marks the default agent', () => {
    expect(agentOptionLabel(makeAgent({ displayName: 'Planner', isDefault: true }))).toBe('Planner (default)')
  })
})
