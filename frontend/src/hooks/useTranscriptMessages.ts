/**
 * Incremental transcript-to-messages rendering with per-entry caching.
 *
 * The transcript view should be a pure function of the transcript, and the
 * transcript is append-only — new entries arrive at the end, existing entries
 * are replaced in place (streaming updates). This hook exploits that
 * structure to avoid O(N) re-computation on every WS event:
 *
 * - Per-entry message cache: each entry is processed once into `Message[]`
 *   and cached by entry id + content reference. When a streaming update
 *   replaces an entry (new object reference), only that entry is
 *   re-processed.
 * - Incremental tool-result index: new entries' tool_results are added to
 *   the existing map without re-scanning the full transcript. When a new
 *   tool_result arrives, previously-cached entries that have matching
 *   tool_use blocks are re-processed so their tool calls get the result.
 * - Dedup state (seenSystem, seenTools) is maintained incrementally — only
 *   entries carrying `system` or `tools` fields affect it, and those are
 *   rare (the backend's delta encoding omits unchanged values).
 *
 * On session change (different first entry id), the cache is cleared and
 * rebuilt from scratch.
 *
 * The caller (`reconcileEntries`) creates new arrays on every WS event but
 * reuses entry object references for unchanged entries, so reference
 * equality (`===`) reliably distinguishes new/changed entries from cached
 * ones.
 */

import { useMemo, useRef } from 'react'
import type { Message, MessageContent, ToolCallInfo, TranscriptEntry } from '../types'
import {
  extractTextFromContent,
  extractThinking,
  extractToolCalls,
  extractToolDefs,
  formatTimestamp,
  tryParsePayload,
} from '../components/ChatArea'

// ── Local helpers (duplicated from ChatArea.tsx — not exported there) ────

interface ToolResultRecord {
  content: string
  isError: boolean | undefined
  exitCode: number | null
}

function parseExitCode(text: string): number | null {
  const m = text.match(/\[exit code:\s*(\d+)\]\s*$/)
  return m ? parseInt(m[1]!, 10) : null
}

function formatToolResultContent(content: unknown): string {
  if (content == null) return ''
  if (typeof content === 'string') return content
  if (Array.isArray(content)) {
    return content
      .map((b) => {
        if (b && typeof b === 'object') {
          const o = b as { type?: string; text?: string; tag?: string; contents?: string }
          if (o.type === 'text' && typeof o.text === 'string') return o.text
          if (o.tag === 'TrpText' && typeof o.contents === 'string') return o.contents
        }
        if (typeof b === 'string') return b
        return JSON.stringify(b)
      })
      .join('\n')
  }
  return JSON.stringify(content, null, 2)
}

// ── Per-entry processing ─────────────────────────────────────────────────

/** Per-entry processing context — the shared state needed to process a
 *  single entry into `Message[]`. */
interface ProcessContext {
  toolResults: Map<string, ToolResultRecord>
  seenSystem: Set<string>
  seenTools: Set<string>
}

/** Process a single transcript entry into `Message[]`, using the shared
 *  tool-result index and dedup sets from the processing context. This is
 *  the per-entry function extracted from `transcriptToMessages` — it's
 *  called once per entry and cached by id. */
function processEntry(e: TranscriptEntry, ctx: ProcessContext): Message[] {
  const ts = formatTimestamp(e.timestamp)
  const rawJson: () => string = () => e.raw || (typeof e.payload === "string" ? e.payload : JSON.stringify(e.payload, null, 2))
  const messages: Message[] = []

  if (e.direction === 'request') {
    const parsed = tryParsePayload(e.payload)
    if (parsed) {
      const opName = (parsed.op as { name?: string } | undefined)?.name
      if (opName === 'SKILL_LOAD' && parsed.result) {
        const input = parsed.input as { id?: string } | undefined
        const result = parsed.result as { body?: string; description?: string; id?: string } | undefined
        const body = result?.body ?? ''
        const channel = e.channel
        const tc: ToolCallInfo = {
          id: 'skillload-' + e.id,
          name: 'SKILL_LOAD',
          input: input ?? {},
          result: body,
          resultIsError: false,
        }
        messages.push({
          id: e.id + '-skillload',
          entryId: e.id,
          agentName: channel ? `Skill · ${channel}` : 'Skill',
          agentStatus: 'completed',
          timestamp: ts,
          blocks: [{ id: 'tc-skillload-' + e.id, toolCall: tc }],
          rawJson,
        })
        return messages
      }
      if (opName === 'SETUP_REPO' && parsed.result) {
        const input = parsed.input as { url?: string } | undefined
        const result = parsed.result as { status?: string; target?: string } | undefined
        const status = result?.status ?? ''
        const target = result?.target ?? ''
        const summary = status === 'cloned' ? `Cloned into ${target}`
                      : status === 'noop' ? `Repo already exists — ${target}`
                      : status === 'conflict' ? `Conflict at ${target}`
                      : status === 'failed' ? 'Clone failed'
                      : status
        const channel = e.channel
        const tc: ToolCallInfo = {
          id: 'setuprepo-' + e.id,
          name: 'SETUP_REPO',
          input: input ?? {},
          result: summary,
          resultIsError: status === 'failed' || status === 'conflict',
        }
        messages.push({
          id: e.id + '-setuprepo',
          entryId: e.id,
          agentName: channel ? `Repo · ${channel}` : 'Repo',
          agentStatus: status === 'failed' ? 'idle' : 'completed',
          timestamp: ts,
          blocks: [{ id: 'tc-setuprepo-' + e.id, toolCall: tc }],
          rawJson,
        })
        return messages
      }
      if (parsed.approval) {
        const opName = (parsed.op as { name?: string } | undefined)?.name ?? 'Unknown'
        const scope = (parsed.approval as { scope?: string }).scope ?? 'unknown'
        const isReject = scope === 'rejected'
        const label = isReject
          ? `Rejected: ${opName}`
          : `Approved: ${opName} (${scope})`
        messages.push({
          id: e.id + '-approval',
          agentName: 'Approval',
          agentStatus: 'completed',
          timestamp: ts,
          blocks: [{ id: 'appr-' + e.id, text: label }],
          rawJson,
        })
        return messages
      }
      // System Prompt and Tools rows: deduplicate by content.
      const sysPrompt = parsed.system as string | undefined
      const tools = parsed.tools
      const hasTools = Array.isArray(tools) && tools.length > 0
      const toolsKey = hasTools ? JSON.stringify(tools) : ''
      const toolDefsBlock = hasTools
        ? (() => {
            const { names, descriptions } = extractToolDefs(tools)
            return { count: names.length, names, descriptions, json: JSON.stringify(tools, null, 2) }
          })()
        : undefined
      if (sysPrompt && !ctx.seenSystem.has(sysPrompt)) {
        ctx.seenSystem.add(sysPrompt)
        messages.push({
          id: e.id + '-sys',
          agentName: 'System Prompt',
          agentStatus: 'idle',
          timestamp: ts,
          blocks: [{ id: 'sys-' + e.id, collapsedText: sysPrompt }],
          rawJson,
        })
      }
      if (toolDefsBlock && !ctx.seenTools.has(toolsKey)) {
        ctx.seenTools.add(toolsKey)
        messages.push({
          id: e.id + '-tools',
          agentName: 'Tools',
          agentStatus: 'idle',
          timestamp: ts,
          blocks: [{ id: 'tools-' + e.id, toolDefs: toolDefsBlock }],
          rawJson,
        })
      }
      const msgs = parsed.messages as Array<{ role: string; content: Array<{ type: string; text?: string; thinking?: string; name?: string; id?: string; input?: unknown }> }> | undefined
      if (msgs && msgs.length > 0) {
        const msg = msgs[msgs.length - 1]!
        const textParts = extractTextFromContent(msg.content)
        const thinkingParts = extractThinking(msg.content)
        const toolCalls = extractToolCalls(msg.content, ctx.toolResults)
        if (msg.role === 'user') {
          if (textParts) {
            messages.push({
              id: e.id + '-user',
              entryId: e.id,
              agentName: e.channel ? `You · ${e.channel}` : 'You',
              agentStatus: 'completed',
              timestamp: ts,
              blocks: [{ id: 'u-' + e.id, text: textParts }],
              meta: parsed.model as string | undefined,
              rawJson,
            })
          }
        } else if (msg.role === 'assistant') {
          const blocks: MessageContent[] = []
          thinkingParts.forEach((tk, i) =>
            blocks.push({ id: 'tk-' + e.id + '-' + i, thinkingText: tk }))
          if (textParts) blocks.push({ id: 'a-' + e.id + '-text', text: textParts })
          for (const tc of toolCalls) blocks.push({ id: 'tc-' + tc.id, toolCall: tc })
          if (blocks.length > 0) {
            messages.push({
              id: e.id + '-asst',
              entryId: e.id,
              agentName: e.model ?? 'Assistant',
              agentStatus: 'completed',
              timestamp: ts,
              blocks,
              rawJson,
            })
          }
        }
      }
    } else {
      messages.push({
        id: e.id,
        agentName: 'You',
        agentStatus: 'completed',
        timestamp: ts,
        blocks: [{ id: 'raw-' + e.id, text: typeof e.payload === 'string' ? e.payload : JSON.stringify(e.payload) }],
        rawJson,
      })
    }
  } else {
    // Response
    const parsed = tryParsePayload(e.payload)
    if (parsed) {
      const content = parsed.content as Array<{ type: string; text?: string; thinking?: string; name?: string; id?: string; input?: unknown }> | undefined
      const textParts = extractTextFromContent(content)
      const thinkingParts = extractThinking(content)
      const toolCalls = extractToolCalls(content, ctx.toolResults)
      const usage = parsed.usage as { input_tokens?: number; output_tokens?: number } | undefined
      const usageMeta = usage
        ? `${usage.input_tokens ?? 0} in / ${usage.output_tokens ?? 0} out tokens`
        : undefined

      const blocks: MessageContent[] = []
      thinkingParts.forEach((tk, i) =>
        blocks.push({ id: 'r-' + e.id + '-tk-' + i, thinkingText: tk }))
      if (textParts) blocks.push({ id: 'r-' + e.id + '-text', text: textParts })
      for (const tc of toolCalls) blocks.push({ id: 'tc-' + tc.id, toolCall: tc })
      if (blocks.length === 0) blocks.push({ id: 'r-' + e.id + '-empty', text: '(empty response)' })

      messages.push({
        id: e.id,
        entryId: e.id,
        agentName: e.model ?? e.harness ?? 'Assistant',
        agentStatus: 'completed',
        timestamp: ts,
        blocks,
        meta: usageMeta,
        rawJson,
        streaming: e.streaming,
      })
    } else {
      messages.push({
        id: e.id,
        agentName: e.harness ?? e.model ?? 'Assistant',
        agentStatus: 'completed',
        timestamp: ts,
        blocks: [{ id: 'raw-' + e.id, text: typeof e.payload === 'string' ? e.payload : JSON.stringify(e.payload) }],
        rawJson,
        streaming: e.streaming,
      })
    }
  }
  return messages
}

// ── Incremental renderer ─────────────────────────────────────────────────

/** Extract tool_use_ids from a cached message array — used to find which
 *  cached entries need re-processing when a new tool_result arrives. */
function extractToolUseIds(msgs: Message[]): Set<string> {
  const ids = new Set<string>()
  for (const m of msgs) {
    for (const b of m.blocks) {
      if (b.toolCall) ids.add(b.toolCall.id)
    }
  }
  return ids
}

/** Extract tool_result ids from an entry's payload. */
function extractToolResultIds(e: TranscriptEntry): Set<string> {
  const ids = new Set<string>()
  const parsed = tryParsePayload(e.payload)
  if (!parsed) return ids
  const msgs = parsed.messages as Array<{ role: string; content: unknown }> | undefined
  if (msgs) {
    for (const m of msgs) {
      if (m.role !== 'user' || !Array.isArray(m.content)) continue
      for (const b of m.content as Array<{ type: string; tool_use_id?: string }>) {
        if (b.type === 'tool_result' && b.tool_use_id) ids.add(b.tool_use_id)
      }
    }
  }
  const respContent = parsed.content as Array<{ type: string; tool_use_id?: string }> | undefined
  if (respContent) {
    for (const b of respContent) {
      if (b.type === 'tool_result' && b.tool_use_id) ids.add(b.tool_use_id)
    }
  }
  return ids
}

/** Cached entry: the entry reference and its derived messages. */
interface CachedEntry {
  entry: TranscriptEntry
  messages: Message[]
}

/** Mutable state for incremental transcript rendering, persisted across
 *  renders in a `useRef`. */
class TranscriptRenderer {
  private cache: Map<string, CachedEntry> = new Map()
  private toolResults: Map<string, ToolResultRecord> = new Map()
  private seenSystem: Set<string> = new Set()
  private seenTools: Set<string> = new Set()
  private lastFirstId: string | null = null

  /** Process the full entries array and return the derived messages.
   *  Only new or changed entries are processed; cached entries are reused. */
  update(entries: TranscriptEntry[]): Message[] {
    if (entries.length === 0) {
      this.reset()
      return []
    }

    // Detect session change: if the first entry id differs, reset everything.
    const firstId = entries[0]!.id
    if (this.lastFirstId !== null && firstId !== this.lastFirstId) {
      this.reset()
    }
    this.lastFirstId = firstId

    const ctx: ProcessContext = {
      toolResults: this.toolResults,
      seenSystem: this.seenSystem,
      seenTools: this.seenTools,
    }

    // First pass: identify new/changed entries and update tool result index.
    const changedIds: Set<string> = new Set()
    const newToolResultIds: Set<string> = new Set()
    const currentIds: Set<string> = new Set()

    for (const e of entries) {
      currentIds.add(e.id)
      const cached = this.cache.get(e.id)

      // Check if entry is unchanged (same reference → same content).
      if (cached !== undefined && cached.entry === e) {
        // Entry unchanged — reuse cache. But still check for new tool results
        // in case this entry was the first to carry them.
        continue
      }

      // Entry is new or changed (different reference or not in cache).
      changedIds.add(e.id)

      // Extract new tool_results from this entry.
      const resultIds = extractToolResultIds(e)
      for (const rid of resultIds) {
        if (!this.toolResults.has(rid)) newToolResultIds.add(rid)
      }
      // Update the tool result index for this entry.
      this.updateToolResults(e)
    }

    // Remove evicted entries from cache (streaming placeholder eviction).
    let dedupRebuildNeeded = false
    for (const [id, cached] of this.cache) {
      if (!currentIds.has(id)) {
        // Check if this entry contributed to dedup sets.
        const parsed = tryParsePayload(cached.entry.payload)
        if (parsed) {
          if (parsed.system) dedupRebuildNeeded = true
          if (Array.isArray(parsed.tools) && parsed.tools.length > 0) dedupRebuildNeeded = true
        }
        this.cache.delete(id)
      }
    }

    // If new tool_results arrived, find cached entries that have tool_use
    // blocks with matching ids and mark them for re-processing.
    if (newToolResultIds.size > 0) {
      for (const [entryId, cached] of this.cache) {
        if (changedIds.has(entryId)) continue
        const toolUseIds = extractToolUseIds(cached.messages)
        for (const newId of newToolResultIds) {
          if (toolUseIds.has(newId)) {
            changedIds.add(entryId)
            break
          }
        }
      }
    }

    // If entries were removed and they carried system/tools, rebuild dedup
    // sets from scratch. This is rare (streaming placeholder eviction).
    if (dedupRebuildNeeded) {
      this.seenSystem.clear()
      this.seenTools.clear()
      // Re-process all entries that carry system/tools.
      for (const e of entries) {
        const parsed = tryParsePayload(e.payload)
        if (parsed && (parsed.system || (Array.isArray(parsed.tools) && parsed.tools.length > 0))) {
          changedIds.add(e.id)
        }
      }
    }

    // Process all changed entries.
    for (const e of entries) {
      if (changedIds.has(e.id)) {
        this.cache.set(e.id, { entry: e, messages: processEntry(e, ctx) })
      }
    }

    // Rebuild the message array from the cache in entry order.
    const messages: Message[] = []
    for (const e of entries) {
      const cached = this.cache.get(e.id)
      if (cached) messages.push(...cached.messages)
    }
    return messages
  }

  private reset(): void {
    this.cache.clear()
    this.toolResults.clear()
    this.seenSystem.clear()
    this.seenTools.clear()
  }

  /** Update the tool result index with tool_results from an entry. */
  private updateToolResults(e: TranscriptEntry): void {
    const parsed = tryParsePayload(e.payload)
    if (!parsed) return
    const msgs = parsed.messages as Array<{ role: string; content: unknown }> | undefined
    if (msgs) {
      for (const m of msgs) {
        if (m.role !== 'user' || !Array.isArray(m.content)) continue
        for (const b of m.content as Array<{ type: string; tool_use_id?: string; content?: unknown; is_error?: boolean }>) {
          if (b.type === 'tool_result' && b.tool_use_id) {
            const raw = formatToolResultContent(b.content)
            this.toolResults.set(b.tool_use_id, {
              content: raw,
              isError: b.is_error,
              exitCode: parseExitCode(raw),
            })
          }
        }
      }
    }
    const respContent = parsed.content as Array<{ type: string; tool_use_id?: string; content?: unknown; is_error?: boolean }> | undefined
    if (respContent) {
      for (const b of respContent) {
        if (b.type === 'tool_result' && b.tool_use_id) {
          const raw = formatToolResultContent(b.content)
          this.toolResults.set(b.tool_use_id, {
            content: raw,
            isError: b.is_error,
            exitCode: parseExitCode(raw),
          })
        }
      }
    }
  }
}

/** React hook: incrementally convert transcript entries to messages.
 *  Uses a ref to persist the renderer state across renders. On session
 *  change (different first entry id), the cache is cleared and rebuilt. */
export function useTranscriptMessages(entries: TranscriptEntry[]): Message[] {
  const ref = useRef<TranscriptRenderer | null>(null)
  if (ref.current === null) {
    ref.current = new TranscriptRenderer()
  }
  return useMemo(() => ref.current!.update(entries), [entries])
}