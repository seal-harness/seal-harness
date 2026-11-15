import type { AgentDefInfo } from '../types'

// ── Agent grouping ───────────────────────────────────────────────────────

/** The display label for an agent's group.  Ungrouped agents (group === null
 *  or empty string) fall under the default "Agents" heading, matching the
 *  behaviour of the backend's available-agents catalog and the flat on-disk
 *  layout (no subdirectory). Mirrors SkillsView.groupLabel. */
export function groupLabel(group: string | null): string {
  const g = group?.trim()
  if (!g) return 'Agents'
  return g
}

/** One display group of agent defs.  `ungrouped` distinguishes the fallback
 *  heading from a real group that happens to be named "Agents", so callers
 *  can render the fallback's members inline (no `optgroup`) when they want. */
export interface AgentGroup {
  label: string
  agents: AgentDefInfo[]
  ungrouped: boolean
}

/** Partition agents into groups in display order.  Ungrouped agents come
 *  first (under "Agents"), then named groups in alphabetical order — matching
 *  the sorting in the backend's prompt catalog. Within a group, agents are
 *  ordered by id. Shared by the Agents view (grouped list pane) and the cron
 *  agent picker (native `<select>` with `optgroup`s) so the two surfaces
 *  present agents in the same order. Mirrors SkillsView.groupSkills. */
export function groupAgents(agents: AgentDefInfo[]): AgentGroup[] {
  const sorted = [...agents].sort((a, b) => {
    const ga = a.group?.trim() ?? ''
    const gb = b.group?.trim() ?? ''
    if (ga !== gb) return ga.localeCompare(gb)
    return a.id.localeCompare(b.id)
  })
  const groups: AgentGroup[] = []
  for (const a of sorted) {
    const label = groupLabel(a.group)
    const ungrouped = (a.group?.trim() ?? '') === ''
    const last = groups[groups.length - 1]
    if (last && last.label === label) {
      last.agents.push(a)
    } else {
      groups.push({ label, agents: [a], ungrouped })
    }
  }
  return groups
}

/** The human-readable label for one agent in a picker: the display name,
 *  falling back to the id when the def has no display name. */
export function agentOptionLabel(a: AgentDefInfo): string {
  const name = a.displayName?.trim() ? a.displayName.trim() : a.id
  return a.isDefault ? `${name} (default)` : name
}
